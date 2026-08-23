#!/usr/bin/env python3
import argparse
import http.cookiejar
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_CONFIG = "/etc/dual-user-sync/config.json"


def die(msg, code=1):
    print(f"[x] {msg}", file=sys.stderr)
    raise SystemExit(code)


def info(msg):
    print(f"[i] {msg}")


def ok(msg):
    print(f"[+] {msg}")


def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)


class Panel:
    def __init__(self, name, cfg):
        self.name = name
        self.base = cfg["url"].rstrip("/") + "/"
        self.username = cfg["username"]
        self.password = cfg["password"]
        self.verify_tls = bool(cfg.get("verify_tls", True))
        self.timeout = int(cfg.get("timeout", 10))
        self.jar = http.cookiejar.CookieJar()
        handlers = [urllib.request.HTTPCookieProcessor(self.jar)]
        if self.base.startswith("https://"):
            if self.verify_tls:
                ctx = ssl.create_default_context()
            else:
                ctx = ssl._create_unverified_context()
            handlers.append(urllib.request.HTTPSHandler(context=ctx))
        self.opener = urllib.request.build_opener(*handlers)

    def url(self, path):
        return self.base + path.lstrip("/")

    def request(self, method, path, payload=None, form=False):
        headers = {"User-Agent": "dual-user-sync/0.1"}
        data = None
        if payload is not None:
            if form:
                data = urllib.parse.urlencode(payload).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                data = json.dumps(payload, separators=(",", ":")).encode()
                headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url(path), data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            raise RuntimeError(f"{self.name}: HTTP {e.code} {path}: {body[:400]}") from e
        except Exception as e:
            raise RuntimeError(f"{self.name}: request failed {path}: {e}") from e
        try:
            return json.loads(raw)
        except Exception as e:
            raise RuntimeError(f"{self.name}: non-JSON response from {path}: {raw[:400]}") from e

    def login(self):
        res = self.request("POST", "login", {"username": self.username, "password": self.password}, form=True)
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: login failed: {res.get('msg','unknown error')}")

    def list_inbounds(self):
        res = self.request("GET", "panel/api/inbounds/list")
        if not res.get("success") or not isinstance(res.get("obj"), list):
            raise RuntimeError(f"{self.name}: cannot list inbounds: {res.get('msg','invalid response')}")
        return res["obj"]

    def add_client(self, inbound_id, client):
        body = {"id": int(inbound_id), "settings": json.dumps({"clients": [client]}, separators=(",", ":"))}
        res = self.request("POST", "panel/api/inbounds/addClient", body)
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: addClient failed for {client.get('email','?')}: {res.get('msg','unknown error')}")

    def update_client(self, inbound_id, existing_auth_id, client):
        cid = urllib.parse.quote(str(existing_auth_id), safe="")
        body = {"id": int(inbound_id), "settings": json.dumps({"clients": [client]}, separators=(",", ":"))}
        res = self.request("POST", f"panel/api/inbounds/updateClient/{cid}", body)
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: updateClient failed for {client.get('email','?')}: {res.get('msg','unknown error')}")

    def delete_client(self, inbound_id, existing_auth_id, email="?"):
        cid = urllib.parse.quote(str(existing_auth_id), safe="")
        res = self.request("POST", f"panel/api/inbounds/{int(inbound_id)}/delClient/{cid}", {})
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: delClient failed for {email}: {res.get('msg','unknown error')}")


def parse_clients(inbound):
    raw = inbound.get("settings", "{}")
    try:
        settings = json.loads(raw) if isinstance(raw, str) else raw
    except Exception as e:
        raise RuntimeError(f"Inbound {inbound.get('id')} has invalid settings JSON: {e}") from e
    clients = settings.get("clients", [])
    if not isinstance(clients, list):
        raise RuntimeError(f"Inbound {inbound.get('id')} settings.clients is not a list")
    return clients


def select_inbound(inbounds, cfg, peer_protocol=None):
    configured = cfg.get("inbound_id")
    if configured not in (None, "", 0, "0"):
        for i in inbounds:
            if int(i.get("id", -1)) == int(configured):
                return i
        raise RuntimeError(f"Configured inbound_id={configured} was not found")

    target_port = int(cfg.get("target_port", 443))
    target_listen = cfg.get("target_listen", "127.0.0.1")
    candidates = []
    for i in inbounds:
        if int(i.get("port", -1)) != target_port:
            continue
        listen = str(i.get("listen", "") or "")
        if target_listen and listen != target_listen:
            continue
        if peer_protocol and str(i.get("protocol", "")) != peer_protocol:
            continue
        candidates.append(i)
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise RuntimeError(f"No inbound matched listen={target_listen!r} port={target_port}" + (f" protocol={peer_protocol}" if peer_protocol else ""))
    ids = ",".join(str(x.get("id")) for x in candidates)
    raise RuntimeError(f"Multiple inbounds matched ({ids}); set inbound_id explicitly in config")


def stable_key(protocol, client):
    email = str(client.get("email", "") or "").strip()
    if email:
        return "email:" + email
    return "auth:" + str(auth_id(protocol, client))


def auth_id(protocol, client):
    p = protocol.lower()
    if p in ("vless", "vmess"):
        return client.get("id")
    if p == "trojan":
        return client.get("password")
    if p == "shadowsocks":
        return client.get("email")
    return client.get("id") or client.get("password") or client.get("email")


def canonical(client):
    return json.dumps(client, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def index_clients(protocol, clients):
    out = {}
    for c in clients:
        k = stable_key(protocol, c)
        if k in out:
            raise RuntimeError(f"Duplicate client identity {k}")
        out[k] = c
    return out


def load_config(path):
    p = Path(path)
    if not p.is_file():
        die(f"Config not found: {path}")
    try:
        cfg = json.loads(p.read_text())
    except Exception as e:
        die(f"Invalid config JSON: {e}")
    for side in ("primary", "secondary"):
        if side not in cfg:
            die(f"Missing config section: {side}")
        for field in ("url", "username", "password"):
            if not cfg[side].get(field):
                die(f"Missing {side}.{field}")
    return cfg


def save_delete_mode(path, enabled):
    p = Path(path)
    cfg = load_config(path)
    cfg["delete_mirroring"] = bool(enabled)
    p.write_text(json.dumps(cfg, indent=2) + "\n")
    p.chmod(0o600)
    ok(f"delete_mirroring={'ON' if enabled else 'OFF'}")


def discover(cfg):
    pa = Panel("Foreign A", cfg["primary"])
    pb = Panel("Foreign B", cfg["secondary"])
    pa.login(); pb.login()
    ia = select_inbound(pa.list_inbounds(), cfg["primary"])
    ib = select_inbound(pb.list_inbounds(), cfg["secondary"], str(ia.get("protocol", "")))
    return pa, pb, ia, ib


def run_sync(cfg, dry_run=False):
    pa, pb, ia, ib = discover(cfg)
    proto = str(ia.get("protocol", "")).lower()
    if proto != str(ib.get("protocol", "")).lower():
        raise RuntimeError(f"Protocol mismatch: A={proto} B={ib.get('protocol')}")
    ac = index_clients(proto, parse_clients(ia))
    bc = index_clients(proto, parse_clients(ib))

    info(f"Primary inbound A: id={ia.get('id')} {ia.get('listen')}:{ia.get('port')} protocol={proto} clients={len(ac)}")
    info(f"Secondary inbound B: id={ib.get('id')} {ib.get('listen')}:{ib.get('port')} protocol={proto} clients={len(bc)}")

    adds = [k for k in ac if k not in bc]
    updates = [k for k in ac if k in bc and canonical(ac[k]) != canonical(bc[k])]
    extras = [k for k in bc if k not in ac]
    delete_enabled = bool(cfg.get("delete_mirroring", False))

    info(f"Plan: add={len(adds)} update={len(updates)} extra_on_B={len(extras)} delete_mirroring={'ON' if delete_enabled else 'OFF'}")
    if dry_run:
        for k in adds: print(f"ADD    {k}")
        for k in updates: print(f"UPDATE {k}")
        for k in extras: print(f"EXTRA  {k}")
        return 0

    for k in adds:
        pb.add_client(ib["id"], ac[k])
        ok(f"Added on B: {k}")
    for k in updates:
        old_id = auth_id(proto, bc[k])
        if not old_id:
            raise RuntimeError(f"Cannot identify existing auth id for {k}")
        pb.update_client(ib["id"], old_id, ac[k])
        ok(f"Updated on B: {k}")
    if delete_enabled:
        for k in extras:
            old_id = auth_id(proto, bc[k])
            if not old_id:
                raise RuntimeError(f"Cannot identify existing auth id for deletion: {k}")
            pb.delete_client(ib["id"], old_id, bc[k].get("email", "?"))
            ok(f"Deleted from B: {k}")
    elif extras:
        warn(f"{len(extras)} client(s) exist only on B; deletion is disabled")

    # Verify primary clients now exist identically on B.
    pb.login()
    ib2 = select_inbound(pb.list_inbounds(), cfg["secondary"], proto)
    bc2 = index_clients(proto, parse_clients(ib2))
    missing = [k for k in ac if k not in bc2]
    mismatch = [k for k in ac if k in bc2 and canonical(ac[k]) != canonical(bc2[k])]
    if missing or mismatch:
        raise RuntimeError(f"Verification failed: missing={len(missing)} mismatch={len(mismatch)}")
    if delete_enabled:
        remaining = [k for k in bc2 if k not in ac]
        if remaining:
            raise RuntimeError(f"Verification failed: {len(remaining)} extra client(s) remain on B")
    ok(f"Sync verified: {len(ac)} primary client(s) mirrored to B")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Mirror 3x-ui inbound clients from Foreign A to Foreign B")
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="login/discover and show changes without writing")
    g.add_argument("--enable-delete", action="store_true", help="enable exact-mirror deletion mode")
    g.add_argument("--disable-delete", action="store_true", help="disable deletion mode")
    args = ap.parse_args()
    if args.enable_delete:
        save_delete_mode(args.config, True); return
    if args.disable_delete:
        save_delete_mode(args.config, False); return
    cfg = load_config(args.config)
    try:
        run_sync(cfg, dry_run=args.check)
    except Exception as e:
        die(str(e), 2)


if __name__ == "__main__":
    main()
