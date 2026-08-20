#!/usr/bin/env bash
set -Eeuo pipefail

UPSTREAM_COMMIT="df7966f8f725837a680ea7b90bd37ea52666c277"
PATCH_REF="10932060a3ef8c42c287a40242444bed28091a27"
GO_VERSION="1.23.1"
GO_SHA256="49bbb517cfa9eee677e1e7897f7cf9cfdbcf49e05f61984a2789136de359f9bd"
STOCK_SHA256="7f1b1439d7fe1d15ae0b376e15614fe13d8a12f6e07a90263e310ea2a9d601fb"
REPO_RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"
BACKUP_DIR="/usr/local/lib/backhaul-ha"
STOCK_BIN="$BACKUP_DIR/backhaul-stock-v0.7.2"
MARKER="/etc/backhaul-ha/custom-v2"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]] || { echo "[x] amd64 only." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "[x] Existing HA install not detected." >&2; exit 2; }
[[ -x /usr/local/bin/backhaul ]] || { echo "[x] /usr/local/bin/backhaul missing." >&2; exit 2; }

for svc in backhaul backhaul-wss backhaul-tcp; do
  systemctl is-active --quiet "$svc" || { echo "[x] $svc is not active. Restore baseline before custom upgrade." >&2; exit 3; }
done

install -d -m 0755 "$BACKUP_DIR"
current_sha="$(sha256sum /usr/local/bin/backhaul | awk '{print $1}')"
if [[ ! -f "$STOCK_BIN" ]]; then
  if [[ "$current_sha" != "$STOCK_SHA256" ]]; then
    echo "[x] Refusing to overwrite unknown Backhaul binary: $current_sha" >&2
    exit 4
  fi
  install -m 0755 /usr/local/bin/backhaul "$STOCK_BIN"
  echo "[+] Stock v0.7.2 binary backed up."
fi

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[x] Missing command: $1" >&2; exit 5; }; }
for c in curl tar python3 sha256sum; do need_cmd "$c"; done

echo "[i] Fetching pinned Go ${GO_VERSION} toolchain..."
curl -fL --retry 4 --retry-delay 2 "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "$work/go.tar.gz"
echo "$GO_SHA256  $work/go.tar.gz" | sha256sum -c - >/dev/null
mkdir -p "$work/toolchain"
tar -xzf "$work/go.tar.gz" -C "$work/toolchain"
GO="$work/toolchain/go/bin/go"
GOFMT="$work/toolchain/go/bin/gofmt"
"$GO" version

echo "[i] Fetching pinned Backhaul source ${UPSTREAM_COMMIT}..."
curl -fL --retry 4 --retry-delay 2 \
  "https://github.com/Musixal/Backhaul/archive/${UPSTREAM_COMMIT}.tar.gz" \
  -o "$work/backhaul-src.tar.gz"
mkdir -p "$work/src"
tar -xzf "$work/backhaul-src.tar.gz" -C "$work/src" --strip-components=1

echo "[i] Fetching pinned custom patch set..."
curl -fsSL --retry 4 --retry-delay 2 \
  "$REPO_RAW/$PATCH_REF/custom-backhaul/apply_patch.py" \
  -o "$work/apply_patch.py"
curl -fsSL --retry 4 --retry-delay 2 \
  "$REPO_RAW/$PATCH_REF/custom-backhaul/fix_wsmux_config.py" \
  -o "$work/fix_wsmux_config.py"
curl -fsSL --retry 4 --retry-delay 2 \
  "$REPO_RAW/$PATCH_REF/custom-backhaul/fix_wss_alpn.py" \
  -o "$work/fix_wss_alpn.py"
python3 "$work/apply_patch.py" "$work/src"
python3 "$work/fix_wsmux_config.py" "$work/src"
python3 "$work/fix_wss_alpn.py" "$work/src"

cd "$work/src"
export GOPROXY="https://proxy.golang.org,direct"
export GOTOOLCHAIN="local"
"$GO" get github.com/refraction-networking/utls@v1.6.7
"$GOFMT" -w \
  config/config.go \
  internal/server/server.go \
  internal/client/client.go \
  internal/server/transport/wsmux.go \
  internal/client/transport/wsmux.go \
  internal/utils/network/ws_dialer.go

grep -F 'alpn.AlpnProtocols = []string{"http/1.1"}' internal/utils/network/ws_dialer.go >/dev/null

echo "[i] Running upstream/custom test suite..."
"$GO" test ./...

echo "[i] Building static custom v2 binary..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO" build -trimpath -ldflags='-s -w' -o "$work/backhaul-custom-v2" .
custom_sha="$(sha256sum "$work/backhaul-custom-v2" | awk '{print $1}')"
[[ -n "$custom_sha" ]] || { echo "[x] Could not hash custom binary." >&2; exit 6; }

install -m 0755 /usr/local/bin/backhaul "$BACKUP_DIR/backhaul-custom-v2-last"
install -m 0755 "$work/backhaul-custom-v2" /usr/local/bin/backhaul

install -d -m 0755 /etc/backhaul-ha
cat > "$MARKER" <<EOF
role=$ROLE
upstream_commit=$UPSTREAM_COMMIT
patch_ref=$PATCH_REF
sha256=$custom_sha
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0644 "$MARKER"

systemctl restart backhaul backhaul-wss backhaul-tcp

echo "[+] Custom Backhaul v2 installed on role=$ROLE"
echo "[+] SHA256: $custom_sha"
echo "[i] Stock rollback binary: $STOCK_BIN"
if command -v tunnel-diagnose >/dev/null 2>&1; then
  echo
  tunnel-diagnose || true
fi
