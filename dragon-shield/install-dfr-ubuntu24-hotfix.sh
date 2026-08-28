#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Pin the known wrapper commit so raw branch caching can never serve an older copy.
BASE_COMMIT="d74aba1add14830a1c9d3c9f46751ffc3afd1dbc"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_COMMIT}/dragon-shield/install-dfr-ubuntu24.sh"

tmp=$(mktemp -t dfr-ubuntu24-hotfix.XXXXXXXX.sh)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --connect-timeout 15 "$BASE_URL" -o "$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# d74 correctly patches both platform guards, but its final grep also matches
# the old guard text embedded inside the Python patcher that prepares managed
# Ingress releases. Remove only those two false-positive verification commands.
lines = []
removed = 0
for line in s.splitlines():
    if line.startswith("! grep -q 'This installer supports Debian only. Detected:' ") and 'runtime platform guard patch failed' in line:
        removed += 1
        continue
    lines.append(line)
if removed != 2:
    raise SystemExit(f'unexpected base wrapper layout: removed={removed}, expected=2')
s = '\n'.join(lines) + '\n'

# Add a real anchored verification after patching. It matches executable shell
# guard lines only, not quoted strings embedded in the Python patcher.
needle = 'log "patched DFR ${DFR_TAG} is ready at ${WORK_ROOT}"'
verify = r'''if grep -Eq '^[[:space:]]*\[\[[[:space:]]*"\$\{ID:-\}"[[:space:]]*==[[:space:]]*"debian"[[:space:]]*\]\][[:space:]]*\|\|[[:space:]]*die[[:space:]]*"This installer supports Debian only\.' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh"; then
  die "Ingress executable Debian-only runtime guard still present"
fi
if grep -Eq '^[[:space:]]*\[\[[[:space:]]*"\$\{ID:-\}"[[:space:]]*==[[:space:]]*"debian"[[:space:]]*\]\][[:space:]]*\|\|[[:space:]]*die[[:space:]]*"This installer supports Debian only\.' "$WORK_ROOT/main-engine/dragon-fruit-relay-egress.sh"; then
  die "Egress executable Debian-only runtime guard still present"
fi

'''
if needle not in s:
    raise SystemExit('verification insertion point not found')
s = s.replace(needle, verify + needle, 1)
p.write_text(s)
PY

bash -n "$tmp"
printf '[dfr-ubuntu24-hotfix] pinned base=%s; launching corrected Ubuntu 24.04 wrapper\n' "$BASE_COMMIT"
exec bash "$tmp" "$@"
