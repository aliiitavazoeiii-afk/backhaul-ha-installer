#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root.' >&2; exit 1; }
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]] || { echo '[x] amd64 only.' >&2; exit 1; }

OUT=/usr/local/bin/backhaul-stealth
UPSTREAM_COMMIT=df7966f8f725837a680ea7b90bd37ea52666c277
PATCH_REF=e9111c6d78a922972482e3de720d1f82dca062d8
GO_VERSION=1.23.1
GO_SHA256=49bbb517cfa9eee677e1e7897f7cf9cfdbcf49e05f61984a2789136de359f9bd
RAW=https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer

if [[ -x "$OUT" ]] && grep -aFq 'ws_control_path' "$OUT" && grep -aFq 'ws_tunnel_path' "$OUT" && grep -aFq 'tls_skip_verify' "$OUT"; then
  echo '[+] Existing custom-v2 capable binary found.'
  sha256sum "$OUT"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates tar python3

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fL --retry 4 --retry-delay 2 "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "$work/go.tar.gz"
echo "$GO_SHA256  $work/go.tar.gz" | sha256sum -c - >/dev/null
mkdir -p "$work/toolchain" "$work/src"
tar -xzf "$work/go.tar.gz" -C "$work/toolchain"
GO="$work/toolchain/go/bin/go"
GOFMT="$work/toolchain/go/bin/gofmt"

curl -fL --retry 4 --retry-delay 2 "https://github.com/Musixal/Backhaul/archive/${UPSTREAM_COMMIT}.tar.gz" -o "$work/src.tar.gz"
tar -xzf "$work/src.tar.gz" -C "$work/src" --strip-components=1

for f in apply_patch.py fix_wsmux_config.py fix_wss_alpn.py; do
  curl -fsSL --retry 4 --retry-delay 2 "$RAW/$PATCH_REF/custom-backhaul/$f" -o "$work/$f"
done
python3 "$work/apply_patch.py" "$work/src"
python3 "$work/fix_wsmux_config.py" "$work/src"
python3 "$work/fix_wss_alpn.py" "$work/src"

cd "$work/src"
export GOPROXY=https://proxy.golang.org,direct
export GOTOOLCHAIN=local
"$GO" get github.com/refraction-networking/utls@v1.6.7
"$GOFMT" -w config/config.go internal/server/server.go internal/client/client.go internal/server/transport/wsmux.go internal/client/transport/wsmux.go internal/utils/network/ws_dialer.go
"$GO" test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO" build -trimpath -ldflags='-s -w' -o "$work/backhaul-stealth" .

install -m 0755 "$work/backhaul-stealth" "$OUT"
grep -aFq 'ws_control_path' "$OUT"
grep -aFq 'ws_tunnel_path' "$OUT"
grep -aFq 'tls_skip_verify' "$OUT"

echo '[+] Custom Backhaul v2 stealth binary installed:'
sha256sum "$OUT"
