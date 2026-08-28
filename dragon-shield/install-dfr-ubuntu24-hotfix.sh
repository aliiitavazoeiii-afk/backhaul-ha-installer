#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_COMMIT="d74aba1add14830a1c9d3c9f46751ffc3afd1dbc"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_COMMIT}/dragon-shield/install-dfr-ubuntu24.sh"
REMOTE_SAFE_COMMIT="a1e26f2b4f2dadda1a029a3254392e299e104b3e"
REMOTE_SAFE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${REMOTE_SAFE_COMMIT}/dragon-shield/dfr-ubuntu24-remote-safe-patch.py"

tmp=$(mktemp -t dfr-ubuntu24-hotfix.XXXXXXXX.sh)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --connect-timeout 15 "$BASE_URL" -o "$tmp"

python3 - "$tmp" "$REMOTE_SAFE_URL" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
remote_safe_url = sys.argv[2]
s = p.read_text()

# d74 patches both Ubuntu platform guards correctly, but its final verification
# also matches quoted patch-source text. Remove only those false-positive checks.
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

needle = 'log "patched DFR ${DFR_TAG} is ready at ${WORK_ROOT}"'
extra = f'''REMOTE_SAFE_PATCH=$(mktemp -t dfr-remote-safe.XXXXXXXX.py)
curl -fsSL --retry 3 --connect-timeout 15 {remote_safe_url!r} -o "$REMOTE_SAFE_PATCH"
python3 "$REMOTE_SAFE_PATCH" "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh"
rm -f "$REMOTE_SAFE_PATCH"
bash -n "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh"
grep -q 'Remote-safe retry: preserving current host package/network state' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh" || die "Ingress remote-safe retry patch failed"
grep -q 'Remote-safe rollback preserved the current host firewall' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh" || die "Ingress remote-safe rollback patch failed"

'''
if needle not in s:
    raise SystemExit('verification insertion point not found')
s = s.replace(needle, extra + needle, 1)
p.write_text(s)
PY

bash -n "$tmp"
printf '[dfr-ubuntu24-hotfix] pinned base=%s; remote-safe patcher=%s\n' "$BASE_COMMIT" "$REMOTE_SAFE_COMMIT"
exec bash "$tmp" "$@"
