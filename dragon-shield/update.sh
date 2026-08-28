#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_URL="https://github.com/aliiitavazoeiii-afk/backhaul-ha-installer.git"
BRANCH="agent/dragon-shield-v1"
BIN="/usr/local/bin/dragon-shield"
TMP=""

log(){ printf '[dragon-shield-update] %s\n' "$*"; }
die(){ printf '[dragon-shield-update] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -r /etc/dragon-shield/server.json || -r /etc/dragon-shield/client.json ]] || die "Dragon Shield config not found"
command -v git >/dev/null 2>&1 || die "git is missing"
command -v systemctl >/dev/null 2>&1 || die "systemctl is missing"

export PATH="/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
command -v go >/dev/null 2>&1 || die "Go is missing; reinstall Dragon Shield once with install.sh"

TMP=$(mktemp -d -t dragon-shield-update.XXXXXXXX)
trap 'rm -rf "$TMP"' EXIT

log "fetching ${BRANCH}"
git clone -q --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/src"
cd "$TMP/src/dragon-shield"

log "building"
GOTOOLCHAIN=local go mod tidy
GOTOOLCHAIN=local go build -trimpath -ldflags='-s -w' -o "$TMP/dragon-shield" ./cmd/dragon-shield

log "installing binary"
install -m 0755 "$TMP/dragon-shield" "${BIN}.new"
mv -f "${BIN}.new" "$BIN"

log "restarting service"
systemctl restart dragon-shield.service
sleep 1
systemctl is-active --quiet dragon-shield.service || {
  systemctl status dragon-shield.service --no-pager || true
  die "service did not become active"
}

log "updated to $($BIN version)"
systemctl status dragon-shield.service --no-pager --lines=8
