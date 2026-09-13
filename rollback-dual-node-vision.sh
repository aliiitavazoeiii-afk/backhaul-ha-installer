#!/usr/bin/env bash
set -Eeuo pipefail
NODE="${1:-}"
case "$NODE" in f1|f2) ;; *) echo "Usage: $0 f1|f2"; exit 2 ;; esac
CONFIG_DIR="/etc/xhttp-dual"; STATE_DIR="/var/lib/xhttp-dual"
REDIRECT_SERVICE="xhttp-dual-${NODE}-vision-redirect.service"; VISION_SERVICE="xhttp-dual-${NODE}-vision.service"
LATEST="$(find "$STATE_DIR/vision-migration-backups" -mindepth 1 -maxdepth 1 -type d -name "*-${NODE}" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1="";sub(/^ /,"");print;exit}')"
[[ -n "$LATEST" && -f "$LATEST/config.json" ]] || { echo "No Vision migration backup found for ${NODE^^}."; exit 1; }
echo "Rollback ${NODE^^} new connections to the old path using: $LATEST"
read -r -p "Type YES: " C; [[ "$C" == YES ]] || exit 0
systemctl disable --now "$REDIRECT_SERVICE" 2>/dev/null || true
cp -a "$LATEST/config.json" "$CONFIG_DIR/config.json"
[[ -f "$LATEST/state.json" ]] && cp -a "$LATEST/state.json" "$STATE_DIR/state.json"
systemctl restart xhttp-dual-controller.service 2>/dev/null || true
echo "Redirect removed. NEW connections now use the old ${NODE^^} SOCKS listener again."
echo "The staged Vision service remains running on its private port so already-established Vision sessions are not deliberately killed."
echo "After they drain, optional: systemctl disable --now $VISION_SERVICE"
