#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root.' >&2; exit 1; }
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]] || { echo '[x] amd64 only.' >&2; exit 1; }

OUT=/usr/local/bin/backhaul-stealth
UPSTREAM_REPO=https://github.com/Musixal/Backhaul.git
UPSTREAM_COMMIT=df7966f8f725837a680ea7b90bd37ea52666c277
PATCH_REF=a1afc641cb307d190fdca0dda62359fead8eed7e
RAW=https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer
MIN_GO=1.23.1

log(){ printf '[+] %s\n' "$*"; }
info(){ printf '[i] %s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

version_ge(){
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

if [[ -x "$OUT" ]] \
  && grep -aFq 'ws_control_path' "$OUT" \
  && grep -aFq 'ws_tunnel_path' "$OUT" \
  && grep -aFq 'tls_skip_verify' "$OUT"; then
  log 'Existing custom-v2 capable binary found.'
  sha256sum "$OUT"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates tar python3 git

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/patches"

info 'Preflight: fetching the four pinned custom patch files...'
for f in apply_patch.py fix_wsmux_config.py fix_wss_alpn.py fix_wss_tunnel_socket_buffers.py; do
  curl -fL --retry 4 --retry-delay 2 --retry-all-errors \
    "$RAW/$PATCH_REF/custom-backhaul/$f" -o "$work/patches/$f" \
    || die "Cannot fetch pinned patch: $f"
  [[ -s "$work/patches/$f" ]] || die "Pinned patch is empty: $f"
done

info 'Preflight: fetching the exact Backhaul v0.7.2 source commit with git...'
git -C "$work/src" init -q
git -C "$work/src" remote add origin "$UPSTREAM_REPO"
git -C "$work/src" fetch -q --depth 1 origin "$UPSTREAM_COMMIT" \
  || die 'Cannot fetch pinned Backhaul source commit.'
git -C "$work/src" checkout -q --detach FETCH_HEAD
actual_commit="$(git -C "$work/src" rev-parse HEAD)"
[[ "$actual_commit" == "$UPSTREAM_COMMIT" ]] \
  || die "Backhaul commit mismatch: got $actual_commit"
log "Backhaul source pinned: $actual_commit"

GO=''
GOFMT=''
if command -v go >/dev/null 2>&1; then
  installed_go="$(go version | awk '{print $3}' | sed 's/^go//')"
  if version_ge "$installed_go" "$MIN_GO"; then
    GO="$(command -v go)"
    GOFMT="$(command -v gofmt)"
    log "Using existing Go $installed_go"
  else
    info "Existing Go $installed_go is older than required $MIN_GO."
  fi
fi

if [[ -z "$GO" ]]; then
  info 'Installing Go 1.23 from the OS package repository...'
  if apt-cache show golang-1.23-go >/dev/null 2>&1; then
    apt-get install -y golang-1.23-go
  else
    die 'golang-1.23-go is not available in this OS repository and no suitable Go is already installed.'
  fi

  for base in /usr/lib/go-1.23/bin /usr/local/go/bin; do
    if [[ -x "$base/go" && -x "$base/gofmt" ]]; then
      pkg_go_ver="$("$base/go" version | awk '{print $3}' | sed 's/^go//')"
      if version_ge "$pkg_go_ver" "$MIN_GO"; then
        GO="$base/go"
        GOFMT="$base/gofmt"
        log "Using packaged Go $pkg_go_ver from $base"
        break
      fi
    fi
  done
fi

[[ -n "$GO" && -x "$GO" ]] || die 'No usable Go compiler found after package installation.'
[[ -n "$GOFMT" && -x "$GOFMT" ]] || die 'No usable gofmt found after package installation.'
"$GO" version

info 'Applying pinned Custom Backhaul v2 patches...'
python3 "$work/patches/apply_patch.py" "$work/src"
python3 "$work/patches/fix_wsmux_config.py" "$work/src"
python3 "$work/patches/fix_wss_alpn.py" "$work/src"
python3 "$work/patches/fix_wss_tunnel_socket_buffers.py" "$work/src"

cd "$work/src"
export GOPROXY='https://proxy.golang.org|direct'
export GOTOOLCHAIN=local

info 'Resolving pinned uTLS dependency...'
"$GO" get github.com/refraction-networking/utls@v1.6.7

"$GOFMT" -w \
  config/config.go \
  internal/server/server.go \
  internal/client/client.go \
  internal/server/transport/wsmux.go \
  internal/client/transport/wsmux.go \
  internal/utils/network/ws_dialer.go

grep -F 'alpn.AlpnProtocols = []string{"http/1.1"}' internal/utils/network/ws_dialer.go >/dev/null \
  || die 'Patched HTTP/1.1 ALPN assertion failed.'
grep -F 'c.config.Mode, 3, 0, 0, c.config.TLSSkipVerify' internal/client/transport/wsmux.go >/dev/null \
  || die 'WSMux tunnel default socket-buffer assertion failed.'

info 'Running upstream/custom Go tests...'
"$GO" test ./...

info 'Building static custom-v2 stealth binary...'
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  "$GO" build -trimpath -ldflags='-s -w' -o "$work/backhaul-stealth" .

[[ -s "$work/backhaul-stealth" ]] || die 'Built binary is missing or empty.'
grep -aFq 'ws_control_path' "$work/backhaul-stealth" || die 'ws_control_path capability missing.'
grep -aFq 'ws_tunnel_path' "$work/backhaul-stealth" || die 'ws_tunnel_path capability missing.'
grep -aFq 'tls_skip_verify' "$work/backhaul-stealth" || die 'tls_skip_verify capability missing.'

install -m 0755 "$work/backhaul-stealth" "$OUT"
log 'Custom Backhaul v2 stealth binary installed:'
sha256sum "$OUT"
