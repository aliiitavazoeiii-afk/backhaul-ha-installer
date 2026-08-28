#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DFR_TAG="${DFR_TAG:-v2.1.0}"
DFR_VERSION="${DFR_TAG#v}"
REPO="ozimellow/dragon-fruit-relay"
WORK_ROOT="/opt/dragon-fruit-relay-ubuntu24-${DFR_VERSION}"
VERIFY_ONLY=0

log(){ printf '[dfr-ubuntu24] %s\n' "$*"; }
die(){ printf '[dfr-ubuntu24] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--verify-only" ]]; then
  VERIFY_ONLY=1
  shift
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -r /etc/os-release ]] || die "/etc/os-release is missing"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "this compatibility installer supports Ubuntu 24.04 LTS only"
[[ -d /run/systemd/system || $VERIFY_ONLY -eq 1 ]] || die "systemd is not active"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl unzip python3 openssl >/dev/null

required_packages=(ca-certificates curl openssl python3-minimal iproute2 iptables iptables-persistent nftables tcpdump strongswan-swanctl charon-systemd dnsutils iputils-ping sudo)
missing=()
for p in "${required_packages[@]}"; do
  apt-cache show "$p" >/dev/null 2>&1 || missing+=("$p")
done
((${#missing[@]} == 0)) || die "Ubuntu repositories are missing required packages: ${missing[*]}"

archive="dragon-fruit-relay-${DFR_VERSION}.zip"
base="https://github.com/${REPO}/releases/download/${DFR_TAG}"
tmp=$(mktemp -d -t dfr-ubuntu24.XXXXXXXX)
trap 'rm -rf "$tmp"' EXIT

log "downloading upstream Dragon Fruit Relay ${DFR_TAG}"
curl -fL --retry 3 --connect-timeout 15 -o "$tmp/$archive" "$base/$archive"
curl -fL --retry 3 --connect-timeout 15 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
line=$(awk -v f="$archive" '$2==f{print;ok=1} END{if(!ok)exit 1}' "$tmp/SHA256SUMS") || die "release checksum entry not found"
printf '%s\n' "$line" > "$tmp/$archive.sha256"
(cd "$tmp" && sha256sum -c "$archive.sha256") >/dev/null || die "upstream release checksum failed"

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"
unzip -q "$tmp/$archive" -d "$tmp/unpacked"
src="$tmp/unpacked/dragon-fruit-relay-${DFR_VERSION}"
[[ -f "$src/install.sh" && -f "$src/main-engine/dragon-fruit-relay-egress.sh" && -f "$src/main-engine/dragon-fruit-relay-ingress.sh" ]] || die "unexpected upstream archive layout"
cp -a "$src/." "$WORK_ROOT/"

python3 - "$WORK_ROOT" <<'PY'
from pathlib import Path
import hashlib, re, sys

root = Path(sys.argv[1])
ingress = root / 'main-engine/dragon-fruit-relay-ingress.sh'
egress = root / 'main-engine/dragon-fruit-relay-egress.sh'

old_guard = '''if [[ "${ID:-}" != "debian" ]]; then
    early_exit "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. Dragon Fruit Relay supports Debian only."
fi'''
new_guard = '''if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
    early_exit "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. This build supports Debian and Ubuntu 24.04 LTS."
fi
if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" != "24.04" ]]; then
    early_exit "Unsupported Ubuntu release: ${PRETTY_NAME:-${VERSION_ID:-unknown}}. This build supports Ubuntu 24.04 LTS only."
fi'''

for p in (ingress, egress):
    s = p.read_text()
    if old_guard not in s:
        raise SystemExit(f'platform guard not found in {p.name}')
    p.write_text(s.replace(old_guard, new_guard, 1))

# Managed Ingress releases are embedded in the Egress script. Patch the decoded
# embedded client before its integrity check and make the expected hash match
# the Ubuntu-compatible client script.
ingress_hash = hashlib.sha256(ingress.read_bytes()).hexdigest()
s = egress.read_text()
s, n = re.subn(r'readonly BUNDLED_INGRESS_SHA256="[0-9a-f]{64}"',
               f'readonly BUNDLED_INGRESS_SHA256="{ingress_hash}"', s, count=1)
if n != 1:
    raise SystemExit('BUNDLED_INGRESS_SHA256 marker not found')
needle = '''    actual=$(sha256sum "$output" | awk '{print $1}')'''
if needle not in s:
    raise SystemExit('embedded ingress checksum point not found')
patch_block = r'''    python3 - "$output" <<'PY_DFR_UBUNTU24'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old=''' + repr(old_guard) + r'''
new=''' + repr(new_guard) + r'''
if old not in s:
    raise SystemExit('embedded ingress platform guard not found')
p.write_text(s.replace(old,new,1))
PY_DFR_UBUNTU24
'''
s = s.replace(needle, patch_block + needle, 1)
egress.write_text(s)

for p in (root/'install.sh', ingress, egress):
    p.chmod(0o755)
print(ingress_hash)
PY

bash -n "$WORK_ROOT/install.sh"
bash -n "$WORK_ROOT/main-engine/dragon-fruit-relay-egress.sh"
bash -n "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh"

grep -q 'Ubuntu 24.04 LTS only' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh" || die "Ingress patch verification failed"
grep -q 'Ubuntu 24.04 LTS only' "$WORK_ROOT/main-engine/dragon-fruit-relay-egress.sh" || die "Egress patch verification failed"

log "patched DFR ${DFR_TAG} is ready at ${WORK_ROOT}"
log "required Ubuntu 24.04 package set is available"

if (( VERIFY_ONLY )); then
  log "verify-only completed successfully"
  exit 0
fi

exec "$WORK_ROOT/install.sh" "$@"
