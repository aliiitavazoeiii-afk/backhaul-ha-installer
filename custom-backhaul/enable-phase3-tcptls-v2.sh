#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"
BASE_REF="35e4025f1c7e339e203ca2211620205080225a19"
BASE_PATH="custom-backhaul/enable-phase3-tcptls.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[x] curl is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[x] python3 is required." >&2; exit 1; }

work="$(mktemp)"
cleanup() { rm -f "$work"; }
trap cleanup EXIT

curl -fsSL --retry 4 --retry-delay 2 \
  "$REPO_RAW/$BASE_REF/$BASE_PATH" -o "$work"

python3 - "$work" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "if 'backend backhaul_tcptls' not in text:"
new = "if not re.search(r'(?m)^backend\\s+backhaul_tcptls\\s*$', text):"
if old not in text:
    raise SystemExit('[x] Expected Phase 3 HAProxy backend guard not found in pinned installer.')
text = text.replace(old, new, 1)
path.write_text(text)
PY

bash -n "$work"
exec bash "$work" "$@"
