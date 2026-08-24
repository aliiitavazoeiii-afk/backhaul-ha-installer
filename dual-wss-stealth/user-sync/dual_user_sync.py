#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import http.cookiejar
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "0.3.0"
DEFAULT_CONFIG = "/etc/dual-user-sync/config.json"
LOCK_FILE = "/run/lock/dual-user-sync.lock"
LOCAL_ONLY_FIELDS = {"created_at", "updated_at"}
NUMERIC_FIELDS = {"limitIp", "totalGB", "expiryTime", "reset", "tgId"}
DEFAULT_FIELDS = {
    "flow": "", "limitIp": 0, "totalGB": 0, "expiryTime": 0,
    "enable": True, "tgId": 0, "subId": "", "comment": "", "reset": 0,
}


def die(msg, code=1):
    print(f"[x] {msg}", file=sys.stderr)
    raise SystemExit(code)


def info(msg):
    print(f"[i] {msg}")


def ok(msg):
    print(f"[+] {msg}")


def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)


def strip_local_metadata(client):
    return {k: v for k, v in client.items() if k not in LOCAL_ONLY_FIELDS}


def normalize_client(client):
    c = strip_local_metadata(client)
    for k, v in DEFAULT_FIELDS.items():
        c.setdefault(k, v)
    for k in NUMERIC_FIELDS:
        if k in c:
            try:
                c[k] = int(c[k] or 0)
            except (TypeError, ValueError):
                pass
    if "enable" in c:
        v = c["enable"]
        c["enable"] = (
            v.strip().lower() in ("1", "true", "yes", "on")
            if isinstance(v, str) else bool(v)
        )
    return c


def canonical(client):
    return json.dumps(
        normalize_client(client), sort_keys=True,
        separators=(",", ":"), ensure_ascii=False
    )


def differing_fields(a, b):
    aa, bb = normalize_client(a), normalize_client(b)
    return [k for k in sorted(set(aa) | set(bb)) if aa.get(k) != bb.get(k)]


def set_hash(index):
    h = hashlib.sha256()
    for key in sorted(index):
        h.update(key.encode())
        h.update(b"\0")
        h.update(canonical(index[key]).encode())
        h.update(b"\n")
    return h.hexdigest()


class RunLock:
    def __enter__(self):
        Path(LOCK_FILE).parent.mkdir(parents=True, exist_ok=True)
        self.f = open(LOCK_FILE, "a+")
        try:
            fcntl.flock(self.f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as e:
            raise RuntimeError("another user-sync run is already active") from e
        return self

    def __exit__(self, *_):
        fcntl.flock(self.f.fileno(), fcntl.LOCK_UN)
        self.f.close()


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
            ctx = ssl.create_default_context() if self.verify_tls else ssl._create_unverified_context()
            handlers.append(urllib.request.HTTPSHandler(context=ctx))
        self.opener = urllib.request.build_opener(*handlers)

    def url(self, path):
        return self.base + path.lstrip("/")

    def request(self, method, path, payload=None, form=False):
        headers = {"User-Agent": f"dual-user-sync/{VERSION}"}
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
            raise RuntimeError(f"{self.name}: login failed: {res.get('msg', 'unknown error')}")

    def list_inbounds(self):
        res = self.request("GET", "panel/api/inbounds/list")
        if not res.get("success") or not isinstance(res.get("obj"), list):
            raise RuntimeError(f"{self.name}: cannot list inbounds: {res.get('msg', 'invalid response')}")
        return res["obj"]

    def add_client(self, inbound_id, client):
        payload = strip_local_metadata(client)
        body = {"id": int(inbound_id), "settings": json.dumps({"clients": [payload]}, separators=(",", ":"))}
        res = self.request("POST", "panel/api/inbounds/addClient", body)
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: addClient failed for {client.get('email', '?')}: {res.get('msg', 'unknown error')}")

    def update_client(self, inbound_id, existing_auth_id, client):
        cid = urllib.parse.quote(str(existing_auth_id), safe="")
        payload = strip_local_metadata(client)
        body = {"id": int(inbound_id), "settings": json.dumps({"clients": [payload]}, separators=(",", ":"))}
        res = self.request("POST", f"panel/api/inbounds/updateClient/{cid}", body)
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: updateClient failed for {client.get('email', '?')}: {res.get('msg', 'unknown error')}")

    def delete_client(self, inbound_id, existing_auth_id, email="?"):
        cid = urllib.parse.quote(str(existing_auth_id), safe="")
        res = self.request("POST", f"panel/api/inbounds/{int(inbound_id)}/delClient/{cid}", {})
        if not res.get("success"):
            raise RuntimeError(f"{self.name}: delClient failed for {email}: {res.get('msg', 'unknown error')}")


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
        for inbound in inbounds:
            if int(inbound.get("id", -1)) == int(configured):
                if peer_protocol and str(inbound.get("protocol", "")).lower() != str(peer_protocol).lower():
                    raise RuntimeError(f"Configured inbound_id={configured} protocol mismatch")
                return inbound
        raise RuntimeError(f"Configured inbound_id={configured} was not found")
    target_port = int(cfg.get("target_port", 443))
    target_listen = cfg.get("target_listen", "127.0.0.1")
    candidates = []
    for inbound in inbounds:
        if int(inbound.get("port", -1)) != target_port:
            continue
        if target_listen and str(inbound.get("listen", "") or "") != target_listen:
            continue
        if peer_protocol and str(inbound.get("protocol", "")).lower() != str(peer_protocol).lower():
            continue
        candidates.append(inbound)
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        suffix = f" protocol={peer_protocol}" if peer_protocol else ""
        raise RuntimeError(f"No inbound matched listen={target_listen!r} port={target_port}{suffix}")
    ids = ",".join(str(x.get("id")) for x in candidates)
    raise RuntimeError(f"Multiple inbounds matched ({ids}); set inbound_id explicitly")


def auth_id(protocol, client):
    p = protocol.lower()
    if p in ("vless", "vmess"):
        return client.get("id")
    if p == "trojan":
        return client.get("password")
    if p == "shadowsocks":
        return client.get("email")
    return client.get("id") or client.get("password") or client.get("email")


def stable_key(protocol, client):
    email = str(client.get("email", "") or "").strip()
    if email:
        return "email:" + email
    aid = auth_id(protocol, client)
    if not aid:
        raise RuntimeError("client has neither email nor usable auth identity")
    return "auth:" + str(aid)


def index_clients(protocol, clients):
    out = {}
    for client in clients:
        key = stable_key(protocol, client)
        if key in out:
            raise RuntimeError(f"Duplicate client identity {key}")
        out[key] = client
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
    guard = cfg.setdefault("delete_guard", {})
    guard.setdefault("allow_empty_primary", False)
    guard.setdefault("max_delete_count", 25)
    guard.setdefault("max_delete_fraction", 0.50)
    return cfg


def save_config(path, cfg):
    p = Path(path)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n")
    tmp.chmod(0o600)
    tmp.replace(p)


def save_delete_mode(path, enabled):
    cfg = load_config(path)
    cfg["delete_mirroring"] = bool(enabled)
    save_config(path, cfg)
    ok(f"delete_mirroring={'ON' if enabled else 'OFF'}")


def discover(cfg):
    pa = Panel("Foreign A", cfg["primary"])
    pb = Panel("Foreign B", cfg["secondary"])
    pa.login()
    pb.login()
    ia = select_inbound(pa.list_inbounds(), cfg["primary"])
    ib = select_inbound(pb.list_inbounds(), cfg["secondary"], str(ia.get("protocol", "")))
    return pa, pb, ia, ib


def validate_delete_plan(cfg, primary_count, secondary_count, extras):
    if not cfg.get("delete_mirroring", False) or not extras:
        return
    guard = cfg["delete_guard"]
    if primary_count == 0 and secondary_count > 0 and not guard["allow_empty_primary"]:
        raise RuntimeError("delete guard blocked sync: primary returned zero clients; intentional full wipe requires delete_guard.allow_empty_primary=true")
    count = len(extras)
    fraction = count / max(secondary_count, 1)
    if count > int(guard["max_delete_count"]):
        raise RuntimeError(f"delete guard blocked sync: {count} deletes > max_delete_count={guard['max_delete_count']}")
    if fraction > float(guard["max_delete_fraction"]):
        raise RuntimeError(f"delete guard blocked sync: {fraction:.1%} delete fraction > max_delete_fraction={float(guard['max_delete_fraction']):.1%}")


def verify(source, secondary, exact):
    missing = [k for k in source if k not in secondary]
    mismatch = [k for k in source if k in secondary and canonical(source[k]) != canonical(secondary[k])]
    extras = [k for k in secondary if k not in source]
    if mismatch:
        for key in mismatch[:5]:
            warn(f"Mismatch {key}: fields={','.join(differing_fields(source[key], secondary[key]))}")
    if missing or mismatch:
        raise RuntimeError(f"Verification failed: missing={len(missing)} mismatch={len(mismatch)}")
    if exact and extras:
        raise RuntimeError(f"Verification failed: {len(extras)} extra client(s) remain on B")
    source_hash = set_hash(source)
    projected = {k: secondary[k] for k in source}
    if source_hash != set_hash(projected):
        raise RuntimeError("Verification hash mismatch")
    if exact:
        if source_hash != set_hash(secondary):
            raise RuntimeError("Exact-mirror hash mismatch")
        ok(f"Exact user-set hash: {source_hash[:16]}...")
    else:
        ok(f"Primary-set hash verified on B: {source_hash[:16]}... (extras_on_B={len(extras)})")


def run_sync(cfg, dry_run=False):
    pa, pb, ia, ib = discover(cfg)
    proto = str(ia.get("protocol", "")).lower()
    if proto != str(ib.get("protocol", "")).lower():
        raise RuntimeError(f"Protocol mismatch: A={proto} B={ib.get('protocol')}")
    ac = index_clients(proto, parse_clients(ia))
    bc = index_clients(proto, parse_clients(ib))
    info(f"Primary A inbound={ia.get('id')} {ia.get('listen')}:{ia.get('port')} protocol={proto} clients={len(ac)}")
    info(f"Secondary B inbound={ib.get('id')} {ib.get('listen')}:{ib.get('port')} protocol={proto} clients={len(bc)}")
    adds = [k for k in ac if k not in bc]
    updates = [k for k in ac if k in bc and canonical(ac[k]) != canonical(bc[k])]
    extras = [k for k in bc if k not in ac]
    delete_enabled = bool(cfg.get("delete_mirroring", False))
    info(f"Plan: add={len(adds)} update={len(updates)} extra_on_B={len(extras)} delete_mirroring={'ON' if delete_enabled else 'OFF'}")
    validate_delete_plan(cfg, len(ac), len(bc), extras)
    if dry_run:
        for key in adds:
            print(f"ADD    {key}")
        for key in updates:
            print(f"UPDATE {key} fields={','.join(differing_fields(ac[key], bc[key]))}")
        for key in extras:
            print(f"EXTRA  {key}")
        if not adds and not updates:
            verify(ac, bc, exact=False)
        else:
            info("Dry-run only: changes pending; no writes made")
        return
    for key in adds:
        pb.add_client(ib["id"], ac[key])
        ok(f"Added on B: {key}")
    for key in updates:
        old_id = auth_id(proto, bc[key])
        if not old_id:
            raise RuntimeError(f"Cannot identify existing auth id for {key}")
        pb.update_client(ib["id"], old_id, ac[key])
        ok(f"Updated on B: {key}")
    if delete_enabled:
        for key in extras:
            old_id = auth_id(proto, bc[key])
            if not old_id:
                raise RuntimeError(f"Cannot identify existing auth id for deletion: {key}")
            pb.delete_client(ib["id"], old_id, bc[key].get("email", "?"))
            ok(f"Deleted from B: {key}")
    elif extras:
        warn(f"{len(extras)} client(s) exist only on B; deletion disabled")
    pb.login()
    ib2 = select_inbound(pb.list_inbounds(), cfg["secondary"], proto)
    bc2 = index_clients(proto, parse_clients(ib2))
    verify(ac, bc2, exact=delete_enabled)
    ok(f"Sync verified: {len(ac)} primary client(s) mirrored to B")


def main():
    ap = argparse.ArgumentParser(description="Mirror 3x-ui inbound clients from Foreign A to Foreign B")
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--version", action="version", version=VERSION)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true")
    g.add_argument("--enable-delete", action="store_true")
    g.add_argument("--disable-delete", action="store_true")
    args = ap.parse_args()
    if args.enable_delete:
        save_delete_mode(args.config, True)
        return
    if args.disable_delete:
        save_delete_mode(args.config, False)
        return
    try:
        with RunLock():
            run_sync(load_config(args.config), dry_run=args.check)
    except Exception as e:
        die(str(e), 2)


if __name__ == "__main__":
    main()
