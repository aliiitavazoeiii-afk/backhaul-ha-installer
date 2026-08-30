#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

APP = "maya-failover"
ETC = Path("/etc/maya-failover")
STATE_DIR = Path("/var/lib/maya-failover")
RUN_DIR = Path("/run/maya-failover")
CFG_PATH = ETC / "config.json"
SECRETS_PATH = ETC / "secrets.env"
VLESS_PATH = ETC / "vless.env"
STATE_PATH = STATE_DIR / "state.json"
XRAY_BIN = Path("/opt/maya-failover/bin/xray")
PROBE_URL = "https://cp.cloudflare.com/generate_204"


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def log(msg):
    print(f"{now_iso()} {msg}", flush=True)


def load_env(path):
    out = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def load_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {} if default is None else default


def atomic_json(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def http_json(url, method="GET", headers=None, body=None, timeout=10):
    payload = None
    hdrs = dict(headers or {})
    if body is not None:
        payload = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=payload, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read().decode()
            return r.status, json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        data = e.read().decode(errors="replace")
        try:
            parsed = json.loads(data)
        except Exception:
            parsed = {"raw": data}
        return e.code, parsed


def tg_call(token, method, params):
    body = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=body,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())


def send_tg(secrets, text):
    try:
        tg_call(secrets["TELEGRAM_BOT_TOKEN"], "sendMessage", {
            "chat_id": secrets["TELEGRAM_CHAT_ID"],
            "text": text,
            "disable_web_page_preview": "true",
        })
    except Exception as e:
        log(f"telegram send failed: {e}")


def cf_headers(secrets):
    return {
        "Authorization": f"Bearer {secrets['CLOUDFLARE_API_TOKEN']}",
        "Accept": "application/json",
    }


def cf_record(secrets, zone_id, record_id):
    status, data = http_json(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}",
        headers=cf_headers(secrets),
    )
    if status != 200 or not data.get("success"):
        raise RuntimeError(f"Cloudflare record read failed: HTTP {status}")
    return data["result"]


def cf_switch(secrets, zone_id, record_id, ip, ttl=60):
    status, data = http_json(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}",
        method="PATCH",
        headers=cf_headers(secrets),
        body={"content": ip, "ttl": ttl, "proxied": False},
    )
    if status != 200 or not data.get("success"):
        raise RuntimeError(f"Cloudflare DNS update failed: HTTP {status}")
    return data["result"]


def parse_vless(uri):
    u = urllib.parse.urlsplit(uri.strip())
    if u.scheme.lower() != "vless":
        raise ValueError("URI is not vless://")
    if not u.username:
        raise ValueError("VLESS UUID is missing")
    q = urllib.parse.parse_qs(u.query, keep_blank_values=True)

    def one(name, default=""):
        return (q.get(name) or [default])[0]

    security = one("security")
    pbk = one("pbk")
    fp = one("fp")
    sni = one("sni")
    sid = one("sid")
    if security != "reality":
        raise ValueError("Only security=reality is supported")
    missing = [k for k, v in (("pbk", pbk), ("fp", fp), ("sni", sni), ("sid", sid)) if not v]
    if missing:
        raise ValueError("Missing VLESS parameters: " + ",".join(missing))
    if one("type", "tcp") not in ("tcp", "raw"):
        raise ValueError("Only TCP/RAW VLESS monitor configs are supported")
    return {
        "id": urllib.parse.unquote(u.username),
        "port": int(u.port or 443),
        "pbk": pbk,
        "fp": fp,
        "sni": sni,
        "sid": sid,
        "spx": urllib.parse.unquote(one("spx", "/")),
        "flow": one("flow", ""),
    }


def free_local_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_port(port, proc, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.15):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def xray_config(creds, target_ip, local_port):
    user = {"id": creds["id"], "encryption": "none"}
    if creds.get("flow"):
        user["flow"] = creds["flow"]
    return {
        "log": {"loglevel": "none"},
        "inbounds": [{
            "listen": "127.0.0.1",
            "port": local_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": False},
        }],
        "outbounds": [{
            "tag": "probe",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": target_ip,
                    "port": creds["port"],
                    "users": [user],
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "fingerprint": creds["fp"],
                    "serverName": creds["sni"],
                    "publicKey": creds["pbk"],
                    "shortId": creds["sid"],
                    "spiderX": creds["spx"],
                },
            },
        }],
    }


def vless_probe(creds, target_ip, timeout=6):
    if not XRAY_BIN.is_file():
        return False, "xray probe binary missing"
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN_DIR, 0o700)
    port = free_local_port()
    cfg = xray_config(creds, target_ip, port)
    fd, cfg_path = tempfile.mkstemp(prefix="probe-", suffix=".json", dir=RUN_DIR)
    os.close(fd)
    Path(cfg_path).write_text(json.dumps(cfg))
    os.chmod(cfg_path, 0o600)
    proc = None
    try:
        proc = subprocess.Popen(
            [str(XRAY_BIN), "run", "-config", cfg_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not wait_port(port, proc, timeout=2.0):
            return False, "xray local socks did not start"
        p = subprocess.run(
            [
                "curl", "-fsS", "-o", "/dev/null",
                "--proxy", f"socks5h://127.0.0.1:{port}",
                "--connect-timeout", "3",
                "--max-time", str(timeout),
                PROBE_URL,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout + 2,
        )
        if p.returncode == 0:
            return True, "full VLESS+Reality e2e OK"
        return False, f"proxy HTTP probe exit={p.returncode}"
    except subprocess.TimeoutExpired:
        return False, "proxy probe timeout"
    except Exception as e:
        return False, str(e)
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    proc.wait(timeout=1)
                except Exception:
                    pass
        try:
            os.unlink(cfg_path)
        except FileNotFoundError:
            pass


def default_service_state():
    return {
        "active_failures": 0,
        "last_dns_ip": None,
        "mode": "unknown",
        "last_active_healthy": None,
        "last_active_detail": None,
        "last_other_healthy": None,
        "last_switch_at": None,
        "blocked_alerted": False,
        "unknown_alerted": False,
    }


def service_mode(svc, ip):
    if ip == svc["main_iran_ip"]:
        return "main"
    if ip == svc["spare_iran_ip"]:
        return "spare"
    return "unknown"


def other_mode(mode):
    return "spare" if mode == "main" else "main"


def switch_to(cfg, secrets, name, svc, state, target, reason):
    ip = svc[f"{target}_iran_ip"]
    rec = cf_switch(
        secrets,
        cfg["cloudflare"]["zone_id"],
        svc["record_id"],
        ip,
        cfg["cloudflare"].get("ttl", 60),
    )
    st = state["services"][name]
    st["mode"] = target
    st["last_dns_ip"] = rec["content"]
    st["active_failures"] = 0
    st["blocked_alerted"] = False
    st["last_switch_at"] = now_iso()
    atomic_json(STATE_PATH, state)
    send_tg(
        secrets,
        f"🔁 {name.upper()} AUTO SWITCH\n"
        f"{svc['domain']}\n"
        f"→ {target.upper()} {ip}\n"
        f"Reason: {reason}\n"
        f"Cloudflare update: OK"
    )


def refresh_dns_modes(cfg, secrets, state):
    for name, svc in cfg["services"].items():
        st = state["services"].setdefault(name, default_service_state())
        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])
        ip = rec["content"]
        mode = service_mode(svc, ip)
        if ip != st.get("last_dns_ip"):
            st["active_failures"] = 0
            st["blocked_alerted"] = False
        st["last_dns_ip"] = ip
        st["mode"] = mode
        if mode == "unknown":
            if not st.get("unknown_alerted"):
                send_tg(secrets, f"⚠️ {name.upper()} automation paused: unexpected DNS IP {ip}.")
                st["unknown_alerted"] = True
        else:
            st["unknown_alerted"] = False
    atomic_json(STATE_PATH, state)


def cycle(cfg, secrets, vless_creds, state):
    threshold = int(cfg["policy"].get("active_failures_before_switch", 3))
    refresh_dns_modes(cfg, secrets, state)

    for name, svc in cfg["services"].items():
        st = state["services"].setdefault(name, default_service_state())
        mode = st.get("mode", "unknown")
        if mode not in ("main", "spare"):
            continue

        active_ip = svc[f"{mode}_iran_ip"]
        ok, detail = vless_probe(vless_creds[name], active_ip)
        st["last_active_healthy"] = ok
        st["last_active_detail"] = detail

        if ok:
            st["active_failures"] = 0
            st["blocked_alerted"] = False
            log(f"{name} mode={mode} ip={active_ip} vless=OK")
            continue

        st["active_failures"] = int(st.get("active_failures", 0)) + 1
        log(f"{name} mode={mode} ip={active_ip} vless=FAIL fails={st['active_failures']} detail={detail}")

        if st["active_failures"] < threshold:
            continue

        target = other_mode(mode)
        target_ip = svc[f"{target}_iran_ip"]
        alt_ok, alt_detail = vless_probe(vless_creds[name], target_ip)
        st["last_other_healthy"] = alt_ok

        if alt_ok:
            reason = f"{threshold} consecutive full VLESS failures on {mode.upper()}"
            try:
                switch_to(cfg, secrets, name, svc, state, target, reason)
            except Exception as e:
                send_tg(secrets, f"⛔ {name.upper()} automatic DNS switch failed: {e}")
        else:
            if not st.get("blocked_alerted"):
                send_tg(
                    secrets,
                    f"🚨 {name.upper()} ACTIVE PATH FAILED x{st['active_failures']}\n"
                    f"Current {mode.upper()} {active_ip}: FAIL\n"
                    f"Other {target.upper()} {target_ip}: FAIL\n"
                    f"DNS NOT changed.\n"
                    f"Active detail: {detail}\n"
                    f"Other detail: {alt_detail}"
                )
                st["blocked_alerted"] = True

    atomic_json(STATE_PATH, state)


def status_text(cfg, state):
    lines = ["📡 Maya VLESS Failover Status"]
    for name, svc in cfg["services"].items():
        st = state["services"].setdefault(name, default_service_state())
        health = st.get("last_active_healthy")
        health_text = "UNKNOWN" if health is None else ("OK" if health else "FAIL")
        lines.append(
            f"{name.upper()}: {st.get('mode','unknown').upper()} "
            f"dns={st.get('last_dns_ip')} "
            f"vless={health_text} "
            f"fails={st.get('active_failures',0)}"
        )
    return "\n".join(lines)


def manual_switch(cfg, secrets, vless_creds, state, name, target):
    svc = cfg["services"][name]
    target_ip = svc[f"{target}_iran_ip"]
    ok, detail = vless_probe(vless_creds[name], target_ip)
    if not ok:
        send_tg(secrets, f"⛔ {name.upper()} manual {target.upper()} blocked: full VLESS probe failed ({detail}).")
        return
    switch_to(cfg, secrets, name, svc, state, target, "manual Telegram command")


def process_telegram_commands(cfg, secrets, vless_creds, state):
    offset = int(state.get("telegram_offset", 0))
    try:
        resp = tg_call(secrets["TELEGRAM_BOT_TOKEN"], "getUpdates", {
            "offset": str(offset),
            "timeout": "0",
            "allowed_updates": json.dumps(["message"]),
        })
    except Exception as e:
        log(f"telegram getUpdates failed: {e}")
        return
    if not resp.get("ok"):
        return

    for upd in resp.get("result", []):
        state["telegram_offset"] = max(int(state.get("telegram_offset", 0)), upd["update_id"] + 1)
        msg = upd.get("message") or {}
        chat_id = str((msg.get("chat") or {}).get("id", ""))
        if chat_id != str(secrets["TELEGRAM_CHAT_ID"]):
            continue
        text = (msg.get("text") or "").strip().lower()

        if text == "/status":
            try:
                refresh_dns_modes(cfg, secrets, state)
            except Exception:
                pass
            send_tg(secrets, status_text(cfg, state))
        elif text in ("/help", "/start"):
            send_tg(
                secrets,
                "Commands:\n"
                "/status\n"
                "/main maya1 | /spare maya1\n"
                "/main maya3 | /spare maya3\n\n"
                "Automatic health = real VLESS+Reality end-to-end test every 15s.\n"
                "3 consecutive failures => healthy alternate is selected automatically."
            )
        else:
            parts = text.split()
            if len(parts) == 2 and parts[0] in ("/main", "/spare") and parts[1] in cfg["services"]:
                manual_switch(cfg, secrets, vless_creds, state, parts[1], parts[0][1:])

    atomic_json(STATE_PATH, state)


def diagnose(cfg, secrets, vless_creds):
    rc = 0
    print("=== MAYA VLESS FAILOVER DIAGNOSTICS ===")
    for name, svc in cfg["services"].items():
        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])
        dns_ip = rec["content"]
        mode = service_mode(svc, dns_ip)
        print(f"{name.upper()} DNS {svc['domain']} -> {dns_ip} ({mode.upper()})")
        for target in ("main", "spare"):
            ip = svc[f"{target}_iran_ip"]
            ok, detail = vless_probe(vless_creds[name], ip)
            print(f"  {target.upper():5} {ip}: {'OK' if ok else 'FAIL'} — {detail}")
        if mode == "unknown":
            rc = 2
    return rc


def main():
    cfg = load_json(CFG_PATH)
    secrets = load_env(SECRETS_PATH)
    vless_env = load_env(VLESS_PATH)

    required = ["TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "CLOUDFLARE_API_TOKEN"]
    missing = [x for x in required if not secrets.get(x)]
    if missing:
        raise SystemExit(f"Missing secrets: {', '.join(missing)}")
    if not XRAY_BIN.is_file():
        raise SystemExit(f"Missing probe binary: {XRAY_BIN}")

    vless_creds = {}
    for name, key in (("maya1", "MAYA1_VLESS"), ("maya3", "MAYA3_VLESS")):
        raw = vless_env.get(key)
        if not raw:
            raise SystemExit(f"Missing {key} in {VLESS_PATH}")
        vless_creds[name] = parse_vless(raw)

    if "--diagnose" in sys.argv:
        raise SystemExit(diagnose(cfg, secrets, vless_creds))

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state = load_json(STATE_PATH, {"services": {}, "telegram_offset": 0})
    state.setdefault("services", {})
    state.setdefault("telegram_offset", 0)

    refresh_dns_modes(cfg, secrets, state)
    interval = int(cfg["policy"].get("interval_seconds", 15))
    threshold = int(cfg["policy"].get("active_failures_before_switch", 3))
    send_tg(
        secrets,
        "✅ Maya VLESS Failover Controller started\n"
        f"Real VLESS health interval: {interval}s\n"
        f"Switch threshold: {threshold} consecutive failures\n"
        "Symmetric MAIN ↔ SPARE failover: ON"
    )

    while True:
        started = time.monotonic()
        try:
            process_telegram_commands(cfg, secrets, vless_creds, state)
            cycle(cfg, secrets, vless_creds, state)
        except Exception as e:
            log(f"cycle error: {e}")
            send_tg(secrets, f"⚠️ Maya Failover Controller error: {e}")
        elapsed = time.monotonic() - started
        time.sleep(max(1, interval - elapsed))


if __name__ == "__main__":
    main()
