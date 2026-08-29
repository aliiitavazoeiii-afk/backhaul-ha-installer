#!/usr/bin/env python3
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

APP = "maya-failover"
ETC = Path("/etc/maya-failover")
STATE_DIR = Path("/var/lib/maya-failover")
CFG_PATH = ETC / "config.json"
SECRETS_PATH = ETC / "secrets.env"
STATE_PATH = STATE_DIR / "state.json"

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
        raise RuntimeError(f"Cloudflare record read failed: HTTP {status} {data}")
    return data["result"]

def cf_switch(secrets, zone_id, record_id, ip, ttl=60):
    status, data = http_json(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}",
        method="PATCH",
        headers=cf_headers(secrets),
        body={"content": ip, "ttl": ttl, "proxied": False},
    )
    if status != 200 or not data.get("success"):
        raise RuntimeError(f"Cloudflare DNS update failed: HTTP {status} {data}")
    return data["result"]

def ping(ip, timeout=2):
    p = subprocess.run(
        ["ping", "-n", "-c", "1", "-W", str(timeout), ip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return p.returncode == 0

def tcp_connect(ip, port, timeout=3):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True, None
    except Exception as e:
        return False, str(e)

def reality_tls_probe(ip, sni, port=443, timeout=5):
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((ip, port), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=sni) as tls:
                cert = tls.getpeercert(binary_form=True)
                version = tls.version()
                return bool(cert or version), version or "tls"
    except Exception as e:
        return False, str(e)

def wss_edge_probe(ip, domain, port=8443, timeout=5):
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((ip, port), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=domain) as tls:
                return True, tls.version() or "tls"
    except Exception as e:
        return False, str(e)

def endpoint_probe(ip, sni):
    tcp_ok, tcp_detail = tcp_connect(ip, 443)
    tls_ok, tls_detail = reality_tls_probe(ip, sni) if tcp_ok else (False, "tcp failed")
    return {
        "ping": ping(ip),
        "tcp443": tcp_ok,
        "reality_tls": tls_ok,
        "tcp_detail": tcp_detail,
        "tls_detail": tls_detail,
        "healthy": bool(tcp_ok and tls_ok),
    }

def spare_probe(svc):
    ep = endpoint_probe(svc["spare_iran_ip"], svc["reality_sni"])
    edge_ok, edge_detail = wss_edge_probe(
        svc["spare_iran_ip"], svc["spare_domain"], svc.get("spare_wss_port", 8443)
    )
    ep["wss_edge"] = edge_ok
    ep["wss_detail"] = edge_detail
    ep["healthy"] = bool(ep["healthy"] and edge_ok)
    return ep

def foreign_diag(ip):
    return {"ping": ping(ip)}

def default_service_state():
    return {
        "main_failures": 0,
        "main_successes": 0,
        "last_main_healthy": None,
        "last_spare_healthy": None,
        "last_dns_ip": None,
        "mode": "unknown",
        "recovery_notified": False,
        "outage_alerted": False,
        "blocked_alerted": False,
        "unknown_alerted": False,
    }

def format_probe(p):
    return f"ping={'OK' if p.get('ping') else 'FAIL'} tcp443={'OK' if p.get('tcp443') else 'FAIL'} realityTLS={'OK' if p.get('reality_tls') else 'FAIL'}"

def switch_to(cfg, secrets, svc_name, svc, state, target):
    ip = svc[f"{target}_iran_ip"]
    rec = cf_switch(
        secrets,
        cfg["cloudflare"]["zone_id"],
        svc["record_id"],
        ip,
        cfg["cloudflare"].get("ttl", 60),
    )
    st = state["services"][svc_name]
    st["mode"] = target
    st["last_dns_ip"] = rec["content"]
    st["recovery_notified"] = False
    atomic_json(STATE_PATH, state)
    send_tg(
        secrets,
        f"🔁 {svc_name.upper()} DNS SWITCH\n"
        f"{svc['domain']}\n"
        f"→ {target.upper()} {ip}\n"
        f"Cloudflare update: OK"
    )

def process_telegram_commands(cfg, secrets, state):
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
            lines = ["📡 Maya Failover Status"]
            for name, svc in cfg["services"].items():
                st = state["services"].setdefault(name, default_service_state())
                lines.append(
                    f"{name.upper()}: mode={st.get('mode')} dns={st.get('last_dns_ip')} "
                    f"fails={st.get('main_failures',0)}"
                )
            send_tg(secrets, "\n".join(lines))
        elif text in ("/help", "/start"):
            send_tg(
                secrets,
                "Commands:\n"
                "/status\n"
                "/main maya1\n"
                "/spare maya1\n"
                "/main maya3\n"
                "/spare maya3"
            )
        else:
            parts = text.split()
            if len(parts) == 2 and parts[0] in ("/main", "/spare") and parts[1] in cfg["services"]:
                target = parts[0][1:]
                name = parts[1]
                svc = cfg["services"][name]
                target_probe = spare_probe(svc) if target == "spare" else endpoint_probe(svc["main_iran_ip"], svc["reality_sni"])
                if not target_probe["healthy"]:
                    send_tg(secrets, f"⛔ {name.upper()} manual {target.upper()} switch blocked: target is not healthy.")
                    continue
                try:
                    switch_to(cfg, secrets, name, svc, state, target)
                except Exception as e:
                    send_tg(secrets, f"⛔ {name.upper()} DNS switch failed: {e}")
    atomic_json(STATE_PATH, state)

def reconcile_dns(cfg, secrets, state):
    for name, svc in cfg["services"].items():
        st = state["services"].setdefault(name, default_service_state())
        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])
        ip = rec["content"]
        st["last_dns_ip"] = ip
        if ip == svc["main_iran_ip"]:
            st["mode"] = "main"
        elif ip == svc["spare_iran_ip"]:
            st["mode"] = "spare"
        else:
            st["mode"] = "unknown"
            if not st.get("unknown_alerted"):
                send_tg(
                    secrets,
                    f"⚠️ {name.upper()} automation paused: {svc['domain']} points to unexpected IP {ip}."
                )
                st["unknown_alerted"] = True
            continue
        st["unknown_alerted"] = False
    atomic_json(STATE_PATH, state)

def cycle(cfg, secrets, state):
    fail_threshold = int(cfg["policy"].get("main_failures_before_failover", 3))
    recover_threshold = int(cfg["policy"].get("main_successes_before_recovery_notice", 10))
    auto_failback = bool(cfg["policy"].get("auto_failback", False))

    for name, svc in cfg["services"].items():
        st = state["services"].setdefault(name, default_service_state())
        main = endpoint_probe(svc["main_iran_ip"], svc["reality_sni"])
        spare = spare_probe(svc)
        mf = foreign_diag(svc["main_foreign_ip"])
        sf = foreign_diag(svc["spare_foreign_ip"])

        st["last_main_healthy"] = main["healthy"]
        st["last_spare_healthy"] = spare["healthy"]
        st["main_foreign_ping"] = mf["ping"]
        st["spare_foreign_ping"] = sf["ping"]

        if main["healthy"]:
            st["main_failures"] = 0
            st["main_successes"] = int(st.get("main_successes", 0)) + 1
            st["outage_alerted"] = False
            st["blocked_alerted"] = False
        else:
            st["main_failures"] = int(st.get("main_failures", 0)) + 1
            st["main_successes"] = 0

        log(
            f"{name} mode={st.get('mode')} main={format_probe(main)} "
            f"spare={format_probe(spare)} edge={'OK' if spare.get('wss_edge') else 'FAIL'} "
            f"fails={st['main_failures']}"
        )

        if st.get("mode") == "unknown":
            continue

        if st.get("mode") == "main" and st["main_failures"] >= fail_threshold:
            if spare["healthy"]:
                if not st.get("outage_alerted"):
                    send_tg(
                        secrets,
                        f"🔴 {name.upper()} MAIN FAILED\n"
                        f"{svc['main_iran_ip']}:443\n"
                        f"{format_probe(main)}\n"
                        f"Spare verified healthy. Switching DNS now."
                    )
                    st["outage_alerted"] = True
                try:
                    switch_to(cfg, secrets, name, svc, state, "spare")
                except Exception as e:
                    send_tg(secrets, f"⛔ {name.upper()} automatic failover failed: {e}")
            else:
                if not st.get("blocked_alerted"):
                    send_tg(
                        secrets,
                        f"🚨 {name.upper()} MAIN FAILED but SPARE is NOT HEALTHY.\n"
                        f"MAIN: {format_probe(main)}\n"
                        f"SPARE: {format_probe(spare)}\n"
                        f"DNS NOT changed."
                    )
                    st["blocked_alerted"] = True

        elif st.get("mode") == "spare" and main["healthy"] and st["main_successes"] >= recover_threshold:
            if not st.get("recovery_notified"):
                send_tg(
                    secrets,
                    f"🟢 {name.upper()} MAIN RECOVERED\n"
                    f"Healthy for {st['main_successes']} checks.\n"
                    f"Current DNS remains on SPARE."
                )
                st["recovery_notified"] = True
            if auto_failback and spare["healthy"]:
                try:
                    switch_to(cfg, secrets, name, svc, state, "main")
                except Exception as e:
                    send_tg(secrets, f"⛔ {name.upper()} automatic failback failed: {e}")

    atomic_json(STATE_PATH, state)

def diagnose(cfg, secrets):
    ok = True
    print("=== MAYA FAILOVER DIAGNOSTICS ===")
    for name, svc in cfg["services"].items():
        mainp = endpoint_probe(svc["main_iran_ip"], svc["reality_sni"])
        sparep = spare_probe(svc)
        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])
        dns_ip = rec["content"]
        known_dns = dns_ip in (svc["main_iran_ip"], svc["spare_iran_ip"])
        print(f"{name.upper()} DNS {svc['domain']} -> {dns_ip}")
        print(f"  MAIN  {svc['main_iran_ip']}: {format_probe(mainp)}")
        print(f"  SPARE {svc['spare_iran_ip']}: {format_probe(sparep)} wssEdge={'OK' if sparep.get('wss_edge') else 'FAIL'}")
        print(f"  Foreign ping MAIN={'OK' if ping(svc['main_foreign_ip']) else 'FAIL'} SPARE={'OK' if ping(svc['spare_foreign_ip']) else 'FAIL'}")
        if not (mainp["healthy"] and sparep["healthy"] and known_dns):
            ok = False
    return 0 if ok else 2

def main():
    cfg = load_json(CFG_PATH)
    secrets = load_env(SECRETS_PATH)
    required = ["TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "CLOUDFLARE_API_TOKEN"]
    missing = [x for x in required if not secrets.get(x)]
    if missing:
        raise SystemExit(f"Missing secrets: {', '.join(missing)}")
    if "--diagnose" in sys.argv:
        raise SystemExit(diagnose(cfg, secrets))
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state = load_json(STATE_PATH, {"services": {}, "telegram_offset": 0})
    state.setdefault("services", {})
    state.setdefault("telegram_offset", 0)

    reconcile_dns(cfg, secrets, state)
    send_tg(
        secrets,
        "✅ Maya Failover Controller started\n"
        "Health interval: 30s\n"
        "Automatic failover: ON\n"
        f"Automatic failback: {'ON' if cfg['policy'].get('auto_failback') else 'OFF'}"
    )

    interval = int(cfg["policy"].get("interval_seconds", 30))
    while True:
        started = time.monotonic()
        try:
            process_telegram_commands(cfg, secrets, state)
            cycle(cfg, secrets, state)
        except Exception as e:
            log(f"cycle error: {e}")
            send_tg(secrets, f"⚠️ Maya Failover Controller error: {e}")
        elapsed = time.monotonic() - started
        time.sleep(max(1, interval - elapsed))

if __name__ == "__main__":
    main()
