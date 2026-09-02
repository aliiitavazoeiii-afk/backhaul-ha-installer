#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_REF="77d4c0cacd1866b391efd02bb35028d07e0165e5"
SOURCE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${SOURCE_REF}/frp-tunnel-ali-shared/install.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --retry 4 "$SOURCE_URL" -o "$TMP"

# On the Iran side, HAProxy must be allowed to start before either Foreign
# backend has registered. The selector/reconcile timer will activate the
# correct slot once its FRP backend is actually listening.
sed -i 's#^ExecStartPost=/usr/local/bin/frp-shared-select restore$#ExecStartPost=/bin/sh -c '\''/usr/local/bin/frp-shared-select restore || true'\''#' "$TMP"

# Drain-safe make-before-break switching:
# enable the new backend first, then disable the old backend. HAProxy's
# runtime "disable server" prevents NEW sessions from selecting the old
# backend but does not forcibly terminate already-established TCP sessions.
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''{
  echo "disable server maya_slots/$other"
  echo "enable server maya_slots/$slot"
} | socat - UNIX-CONNECT:"$SOCK" >/dev/null
'''
new = '''{
  echo "enable server maya_slots/$slot"
  echo "disable server maya_slots/$other"
} | socat - UNIX-CONNECT:"$SOCK" >/dev/null
'''
if old not in s:
    raise SystemExit("ERROR: failed to locate selector switch block")
p.write_text(s.replace(old, new, 1))
PY

grep -q "ExecStartPost=/bin/sh -c '/usr/local/bin/frp-shared-select restore || true'" "$TMP" || {
  echo "ERROR: failed to apply safe first-boot patch" >&2
  exit 1
}
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assert 'echo "enable server maya_slots/$slot"\n  echo "disable server maya_slots/$other"' in s
PY

bash -n "$TMP"
exec bash "$TMP" "$@"
