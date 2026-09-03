#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="/usr/local/bin/tunnel-diagnose"
MARKER="/etc/backhaul-ha/phase3-tcptls"
BACKUP="/usr/local/lib/backhaul-ha/tunnel-diagnose-pre-phase3"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
[[ -f "$MARKER" ]] || { echo "[x] Phase 3 marker missing: $MARKER" >&2; exit 2; }
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

if "Phase 3 stunnel TLS :9444 listening" in text:
    print("[i] Diagnostics are already Phase-3-aware.")
    raise SystemExit(0)

old = "  ss -lntp 2>/dev/null | grep -q ':3080 ' && ok 'TCPMux control :3080 listening' || fail 'TCPMux control :3080 missing'"
new = r'''  if [[ -f /etc/backhaul-ha/phase3-tcptls ]]; then
    svc backhaul-tcptls
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:9444' && ok 'Phase 3 stunnel TLS :9444 listening' || fail 'Phase 3 stunnel TLS :9444 missing'
    ss -lntp 2>/dev/null | grep -q '127.0.0.1:18081' && ok 'Phase 3 Backhaul TCPMux :18081 listening' || fail 'Phase 3 Backhaul TCPMux :18081 missing'
    grep -Eq '^[[:space:]]*server[[:space:]]+tcptls_control[[:space:]]+127\.0\.0\.1:9444([[:space:]]|$)' /etc/haproxy/haproxy.cfg 2>/dev/null && ok 'HAProxy TCPMux TLS backend targets stunnel :9444' || fail 'HAProxy TCPMux TLS backend is not targeting stunnel :9444'
    if ss -lntp 2>/dev/null | grep -q ':3080 '; then
      warn 'legacy raw TCPMux :3080 is still exposed'
    else
      ok 'legacy raw TCPMux :3080 is not exposed (expected in Phase 3)'
    fi
  else
    ss -lntp 2>/dev/null | grep -q ':3080 ' && ok 'TCPMux control :3080 listening' || fail 'TCPMux control :3080 missing'
  fi'''

if old not in text:
    raise SystemExit("[x] Expected TCPMux :3080 listener check not found; refusing an ambiguous patch.")

text = text.replace(old, new, 1)
if 'VERSION="1.3.1-phase2"' in text:
    text = text.replace('VERSION="1.3.1-phase2"', 'VERSION="1.3.2-phase3"', 1)
elif 'VERSION="1.3.0"' in text:
    text = text.replace('VERSION="1.3.0"', 'VERSION="1.3.2-phase3"', 1)
else:
    raise SystemExit("[x] Unsupported tunnel-diagnose version marker.")

path.write_text(text)
print("[+] Patched tunnel-diagnose for Phase 3 TCPMux TLS checks.")
PY

chmod 0755 "$TARGET"
bash -n "$TARGET"

echo "[+] Phase 3 diagnostics upgrade complete."
echo "[i] Run: tunnel-diagnose --deep"
