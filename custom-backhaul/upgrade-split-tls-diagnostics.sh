#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="/usr/local/bin/tunnel-diagnose"
SPLIT_MARKER="/etc/backhaul-ha/phase2-split-tls"
BACKUP="/usr/local/lib/backhaul-ha/tunnel-diagnose-pre-split-tls"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
[[ -f "$SPLIT_MARKER" ]] || { echo "[x] Split-TLS marker missing: $SPLIT_MARKER" >&2; exit 2; }
[[ -f "$TARGET" ]] || { echo "[x] Missing $TARGET" >&2; exit 2; }

install -d -m 0755 /usr/local/lib/backhaul-ha
if [[ ! -f "$BACKUP" ]]; then
  install -m 0755 "$TARGET" "$BACKUP"
  echo "[+] Backed up existing diagnostics to $BACKUP"
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "Phase 2 split-TLS stunnel :9443 listening" in text:
    print("[i] Diagnostics are already split-TLS-aware.")
    raise SystemExit(0)

old = r'''  if [[ -f /etc/backhaul-ha/phase2-stealth-wss ]]; then
    svc nginx
    nginx -t >/dev/null 2>&1 && ok 'nginx Phase 2 config valid' || fail 'nginx Phase 2 config invalid'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:9443' && ok 'Phase 2 nginx TLS :9443 listening' || fail 'Phase 2 nginx TLS :9443 missing'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:18080' && ok 'Phase 2 Backhaul WSMux :18080 listening' || fail 'Phase 2 Backhaul WSMux :18080 missing'
    grep -Eq '^[[:space:]]*server[[:space:]]+wss_control[[:space:]]+127\.0\.0\.1:9443([[:space:]]|$)' /etc/haproxy/haproxy.cfg 2>/dev/null && ok 'HAProxy backbone SNI targets nginx :9443' || fail 'HAProxy backbone SNI is not targeting nginx :9443'
    if ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443'; then
      warn 'legacy direct WSS :8443 is still exposed on loopback'
    else
      ok 'legacy direct WSS :8443 is not exposed (expected in Phase 2)'
    fi
  else
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443' && ok 'WSSMux control :8443 listening' || fail 'WSSMux control :8443 missing'
  fi'''

new = r'''  if [[ -f /etc/backhaul-ha/phase2-split-tls ]]; then
    svc backhaul-wss-tls
    svc nginx
    nginx -t >/dev/null 2>&1 && ok 'nginx split-TLS config valid' || fail 'nginx split-TLS config invalid'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:9443' && ok 'Phase 2 split-TLS stunnel :9443 listening' || fail 'Phase 2 split-TLS stunnel :9443 missing'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:9080' && ok 'Phase 2 nginx HTTP :9080 listening' || fail 'Phase 2 nginx HTTP :9080 missing'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:18080' && ok 'Phase 2 Backhaul WSMux :18080 listening' || fail 'Phase 2 Backhaul WSMux :18080 missing'
    grep -Eq '^[[:space:]]*server[[:space:]]+wss_control[[:space:]]+127\.0\.0\.1:9443([[:space:]]|$)' /etc/haproxy/haproxy.cfg 2>/dev/null && ok 'HAProxy backbone SNI targets split-TLS stunnel :9443' || fail 'HAProxy backbone SNI is not targeting split-TLS stunnel :9443'
    grep -Eq '^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:9080;' /etc/nginx/sites-available/backhaul-decoy 2>/dev/null && ok 'nginx decoy owns plain loopback HTTP :9080' || fail 'nginx decoy is not plain loopback HTTP :9080'
    if grep -Eq '^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:9443[[:space:]]+ssl' /etc/nginx/sites-available/backhaul-decoy 2>/dev/null; then
      fail 'nginx still owns TLS :9443 in split-TLS mode'
    else
      ok 'nginx no longer owns TLS termination'
    fi
    if ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443'; then
      warn 'legacy direct WSS :8443 is still exposed on loopback'
    else
      ok 'legacy direct WSS :8443 is not exposed (expected in Phase 2)'
    fi
  elif [[ -f /etc/backhaul-ha/phase2-stealth-wss ]]; then
    svc nginx
    nginx -t >/dev/null 2>&1 && ok 'nginx Phase 2 config valid' || fail 'nginx Phase 2 config invalid'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:9443' && ok 'Phase 2 nginx TLS :9443 listening' || fail 'Phase 2 nginx TLS :9443 missing'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:18080' && ok 'Phase 2 Backhaul WSMux :18080 listening' || fail 'Phase 2 Backhaul WSMux :18080 missing'
    grep -Eq '^[[:space:]]*server[[:space:]]+wss_control[[:space:]]+127\.0\.0\.1:9443([[:space:]]|$)' /etc/haproxy/haproxy.cfg 2>/dev/null && ok 'HAProxy backbone SNI targets nginx :9443' || fail 'HAProxy backbone SNI is not targeting nginx :9443'
    if ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443'; then
      warn 'legacy direct WSS :8443 is still exposed on loopback'
    else
      ok 'legacy direct WSS :8443 is not exposed (expected in Phase 2)'
    fi
  else
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443' && ok 'WSSMux control :8443 listening' || fail 'WSSMux control :8443 missing'
  fi'''

if old not in text:
    raise SystemExit("[x] Expected Phase-2-aware diagnostics block not found; refusing ambiguous patch.")

text = text.replace(old, new, 1)
if 'VERSION="1.3.2-phase3"' in text:
    text = text.replace('VERSION="1.3.2-phase3"', 'VERSION="1.3.3-splittls"', 1)
elif 'VERSION="1.3.1-phase2"' in text:
    text = text.replace('VERSION="1.3.1-phase2"', 'VERSION="1.3.3-splittls"', 1)
else:
    raise SystemExit("[x] Unsupported tunnel-diagnose version marker.")

path.write_text(text)
print("[+] Patched tunnel-diagnose for Phase 2 split-TLS checks.")
PY

chmod 0755 "$TARGET"
bash -n "$TARGET"

echo "[+] Split-TLS diagnostics upgrade complete."
echo "[i] Run: tunnel-diagnose --deep"
