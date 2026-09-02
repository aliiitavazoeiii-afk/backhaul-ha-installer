#!/usr/bin/env bash
set -Eeuo pipefail

CLI=/usr/local/bin/frp-tunnel
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -f "$CLI" ]] || { echo "Missing $CLI" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

ts=$(date +%Y%m%d-%H%M%S)
backup="${CLI}.pre-health-pipefail-${ts}.bak"
cp -a "$CLI" "$backup"

python3 - "$CLI" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

replacements = [
    (
        '  resolved_iran_ips | grep -Fxq "$IRAN_IP"',
        '  grep -Fxq "$IRAN_IP" <<<"$(resolved_iran_ips)"',
    ),
    (
        '  if "$FRPC" status -c "$ETC/frpc.toml" 2>/dev/null | grep -Eiq "ali-vpn-${PROFILE}.*(running|online|start|success)"; then',
        '  if grep -Eiq "ali-vpn-${PROFILE}.*(running|online|start|success)" <<<"$("$FRPC" status -c "$ETC/frpc.toml" 2>/dev/null || true)"; then',
    ),
    (
        "  elif journalctl -u \"$SERVICE\" --since '-5 minutes' --no-pager 2>/dev/null |\n       grep -Eq 'start proxy success|login to server success'; then",
        "  elif grep -Eq 'start proxy success|login to server success' <<<\"$(journalctl -u \"$SERVICE\" --since '-5 minutes' --no-pager 2>/dev/null || true)\"; then",
    ),
    (
        '    ss -H -ltn "sport = :$CONTROL_PORT" 2>/dev/null | grep -q . && cstate=up || cstate=down',
        '    [[ -n "$(ss -H -ltn "sport = :$CONTROL_PORT" 2>/dev/null)" ]] && cstate=up || cstate=down',
    ),
    (
        '    if ss -H -ltn "sport = :$PUBLIC_PORT" 2>/dev/null | grep -q .; then',
        '    if [[ -n "$(ss -H -ltn "sport = :$PUBLIC_PORT" 2>/dev/null)" ]]; then',
    ),
    (
        "    elif journalctl -u \"$SERVICE\" -b --no-pager 2>/dev/null | grep -Eq 'new proxy .*success|start proxy success'; then",
        "    elif grep -Eq 'new proxy .*success|start proxy success' <<<\"$(journalctl -u \"$SERVICE\" -b --no-pager 2>/dev/null || true)\"; then",
    ),
]

changed = 0
for old, new in replacements:
    if old in s:
        s = s.replace(old, new, 1)
        changed += 1
    elif new in s:
        # Idempotent rerun.
        pass
    else:
        raise SystemExit(f"Expected health pattern not found; refusing partial patch: {old[:80]}")

p.write_text(s)
print(f"Patched {changed} health pipeline(s).")
PY

bash -n "$CLI" || {
  cp -a "$backup" "$CLI"
  echo "Syntax validation failed; restored $backup" >&2
  exit 1
}
chmod 0755 "$CLI"

echo "Health CLI fixed. No FRP, nginx, Xray, or x-ui service was restarted."
echo "Backup: $backup"
echo
"$CLI" health || true
