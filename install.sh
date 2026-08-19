#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_VERSION="1.3.0"
REPO_RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"
CORE_COMMIT="637844c6ba610ca3ab83876d314932d427a376a6"
CORE_URL="$REPO_RAW/$CORE_COMMIT/install.sh"
FAILOVER_URL="$REPO_RAW/main/enable-transport-failover.sh"
DIAG_URL="$REPO_RAW/main/enable-diagnostics.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[x] curl is required." >&2; exit 1; }

tmp="$(mktemp)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

echo "[i] Backhaul HA Installer $PROJECT_VERSION"
echo "[i] Running pinned, previously-tested tunnel installer core..."
curl -fsSL --retry 4 --retry-delay 2 "$CORE_URL" -o "$tmp"
bash "$tmp" "$@"

echo
echo "[i] Enabling three-path automatic failover (WSSMux -> TCPMux -> plain TCP)..."
if bash <(curl -fsSL --retry 4 --retry-delay 2 "$FAILOVER_URL"); then
  echo "[+] Three-path failover ready."
else
  echo "[!] Base tunnel installation succeeded, but third transport setup failed." >&2
  echo "[!] Existing WSSMux/TCPMux configuration is preserved." >&2
  exit 4
fi

echo
echo "[i] Installing/updating tunnel diagnostics..."
if bash <(curl -fsSL --retry 4 --retry-delay 2 "$DIAG_URL"); then
  echo "[+] Diagnostics ready: tunnel-diagnose"
  echo "[+] Speed diagnostics: tunnel-diagnose --deep"
  echo "[+] Targeted repair: tunnel-diagnose --repair"
else
  echo "[!] Tunnel installation succeeded, but diagnostic setup failed." >&2
  echo "[!] Re-run this installer later to retry diagnostics; tunnel configuration is preserved." >&2
  exit 3
fi
