#!/usr/bin/env bash
set -Eeuo pipefail

# Fresh-server orchestrator for the validated Custom Backhaul v2 lab baseline.
#
# Deployment remains intentionally two-stage because Iran generates the shared
# secret bundle and the Foreign role must receive that bundle before it can be
# configured safely.

REPO_RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"

# Pinned production baseline used to bootstrap stock Backhaul HA.
BASE_CORE_REF="637844c6ba610ca3ab83876d314932d427a376a6"
BASE_RELEASE_REF="c4415857c874639b32365a6802cc7ccd36406c7a"

# Pinned custom payload that passed the final lab validation/reboot baseline.
PAYLOAD_REF="9aaa19300b1a76389695570b0652a2dae19b8743"

CORE_URL="$REPO_RAW/$BASE_CORE_REF/install.sh"
FAILOVER_URL="$REPO_RAW/$BASE_RELEASE_REF/enable-transport-failover.sh"
DIAG_URL="$REPO_RAW/$BASE_RELEASE_REF/enable-diagnostics.sh"
CUSTOM_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/install-lab-v2.sh"
PHASE2_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/enable-stealth-wss.sh"
PHASE2_DIAG_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/upgrade-phase2-diagnostics.sh"
SPLIT_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/upgrade-phase2-split-tls.sh"
PHASE3_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/enable-phase3-tcptls-v2.sh"
PHASE3_DIAG_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/upgrade-phase3-diagnostics.sh"
SPLIT_DIAG_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/upgrade-split-tls-diagnostics.sh"
VERIFY_PHASE2_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/verify-stealth-wss.sh"
VERIFY_SPLIT_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/verify-phase2-split-tls.sh"
VERIFY_PHASE3_URL="$REPO_RAW/$PAYLOAD_REF/custom-backhaul/verify-phase3-tcptls.sh"

ROLE=""
IRAN_IP=""
FOREIGN_IP=""
WSS_DOMAIN=""
TCP_DOMAIN=""
BUNDLE="/root/backhaul-ha-secrets.env"
INSTALL_XUI=""
PANEL_PORT=""
NON_INTERACTIVE=0
SKIP_DNS_CHECK=0

usage() {
  cat <<'EOF'
Custom Backhaul v2 fresh-server installer

Iran first:
  bash install-final-v2.sh \
    --role iran \
    --iran-ip IRAN_IP \
    --foreign-ip FOREIGN_IP \
    --wss-domain WSS_DOMAIN \
    --tcp-domain TCP_TLS_DOMAIN

Foreign after copying /root/backhaul-ha-secrets.env from Iran:
  bash install-final-v2.sh \
    --role foreign \
    --bundle /root/backhaul-ha-secrets.env

Optional base-installer arguments:
  --install-xui yes|no
  --panel-port PORT
  --non-interactive
  --skip-dns-check

Notes:
- Run Iran first.
- WSS_DOMAIN and TCP_TLS_DOMAIN must be different A records pointing to Iran.
- Do not paste the generated secrets bundle into chat/logs; copy it directly to Foreign.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2 ;;
    --foreign-ip) FOREIGN_IP="${2:-}"; shift 2 ;;
    --wss-domain|--domain) WSS_DOMAIN="${2:-}"; shift 2 ;;
    --tcp-domain) TCP_DOMAIN="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --install-xui) INSTALL_XUI="${2:-}"; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[x] Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "[x] --role must be iran or foreign." >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "[x] curl is required." >&2; exit 1; }

run_url() {
  local url="$1"; shift
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 4 --retry-delay 2 "$url" -o "$tmp"
  bash -n "$tmp"
  bash "$tmp" "$@"
  rm -f "$tmp"
}

base_optional_args=()
[[ -n "$INSTALL_XUI" ]] && base_optional_args+=(--install-xui "$INSTALL_XUI")
[[ -n "$PANEL_PORT" ]] && base_optional_args+=(--panel-port "$PANEL_PORT")
(( NON_INTERACTIVE == 1 )) && base_optional_args+=(--non-interactive)
(( SKIP_DNS_CHECK == 1 )) && base_optional_args+=(--skip-dns-check)

if [[ "$ROLE" == "iran" ]]; then
  [[ -n "$IRAN_IP" ]] || { echo "[x] --iran-ip is required for Iran." >&2; exit 2; }
  [[ -n "$FOREIGN_IP" ]] || { echo "[x] --foreign-ip is required for Iran." >&2; exit 2; }
  [[ -n "$WSS_DOMAIN" ]] || { echo "[x] --wss-domain is required for Iran." >&2; exit 2; }
  [[ -n "$TCP_DOMAIN" ]] || { echo "[x] --tcp-domain is required for Iran." >&2; exit 2; }
  [[ "$WSS_DOMAIN" != "$TCP_DOMAIN" ]] || { echo "[x] WSS and TCPMux TLS domains must differ." >&2; exit 2; }

  echo "[1/10] Installing pinned stock HA baseline on Iran..."
  run_url "$CORE_URL" \
    --role iran \
    --iran-ip "$IRAN_IP" \
    --foreign-ip "$FOREIGN_IP" \
    --domain "$WSS_DOMAIN" \
    "${base_optional_args[@]}"

  echo "[2/10] Enabling pinned three-path failover baseline..."
  run_url "$FAILOVER_URL"

  echo "[3/10] Installing pinned baseline diagnostics..."
  run_url "$DIAG_URL"

  echo "[4/10] Replacing stock Backhaul with validated custom v2 binary..."
  run_url "$CUSTOM_URL"

  echo "[5/10] Enabling deployment-specific WSS paths and decoy ingress..."
  run_url "$PHASE2_URL"
  run_url "$PHASE2_DIAG_URL"

  echo "[6/10] Applying validated split-TLS WSS topology..."
  run_url "$SPLIT_URL"

  echo "[7/10] Enabling separate-SNI TLS-wrapped TCPMux backup..."
  run_url "$PHASE3_URL" --domain "$TCP_DOMAIN"

  echo "[8/10] Updating diagnostics for Phase 3 and split-TLS..."
  run_url "$PHASE3_DIAG_URL"
  run_url "$SPLIT_DIAG_URL"

  echo "[9/10] Verifying final Iran topology..."
  run_url "$VERIFY_SPLIT_URL"
  run_url "$VERIFY_PHASE3_URL"

  echo "[10/10] Final non-deep health diagnostics..."
  tunnel-diagnose || true

  echo
  echo "[+] Iran fresh install complete."
  echo "[+] WSS: $WSS_DOMAIN:443 -> HAProxy -> stunnel :9443 -> nginx :9080 -> WSMux :18080"
  echo "[+] TCPMux TLS: $TCP_DOMAIN:443 -> HAProxy -> stunnel :9444 -> TCPMux :18081"
  echo "[+] Plain emergency path remains IP-restricted."
  echo
  echo "[NEXT] Copy $BUNDLE directly to the Foreign server, then run this installer there with --role foreign."
  echo "[NEXT] Do not paste the bundle contents into chat or public logs."
else
  [[ -f "$BUNDLE" ]] || { echo "[x] Missing Foreign bundle: $BUNDLE" >&2; exit 2; }
  chmod 0600 "$BUNDLE"

  echo "[1/8] Installing pinned stock HA baseline on Foreign..."
  run_url "$CORE_URL" \
    --role foreign \
    --bundle "$BUNDLE" \
    "${base_optional_args[@]}"

  echo "[2/8] Enabling pinned three-path failover baseline..."
  run_url "$FAILOVER_URL"

  echo "[3/8] Installing pinned baseline diagnostics..."
  run_url "$DIAG_URL"

  echo "[4/8] Replacing stock Backhaul with validated custom v2 binary..."
  run_url "$CUSTOM_URL"

  echo "[5/8] Enabling deployment-specific WSS client configuration..."
  run_url "$PHASE2_URL"
  run_url "$PHASE2_DIAG_URL"
  run_url "$VERIFY_PHASE2_URL"

  echo "[6/8] Enabling separate-SNI TLS-wrapped TCPMux client..."
  run_url "$PHASE3_URL"

  echo "[7/8] Updating Phase 3 diagnostics and verifying..."
  run_url "$PHASE3_DIAG_URL"
  run_url "$VERIFY_PHASE3_URL"

  echo "[8/8] Final non-deep health diagnostics..."
  tunnel-diagnose || true

  echo
  echo "[+] Foreign fresh install complete."
  echo "[+] Custom Backhaul v2, WSSMux primary, TLS-wrapped TCPMux backup, and plain emergency path are configured."
  echo "[NEXT] On Iran run: tunnel-diagnose --deep"
  echo "[NEXT] Then reboot both hosts once and confirm the VPN client remains functional."
fi
