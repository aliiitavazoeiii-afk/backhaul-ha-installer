#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="agent/dual-control-panel"
REPO="aliiitavazoeiii-afk/backhaul-ha-installer"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
BIN="/usr/local/bin/dualctl"
STATE_DIR="/etc/dual-control-panel"
STATE_FILE="${STATE_DIR}/state.env"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root.' >&2; exit 1; }
source /etc/os-release 2>/dev/null || { echo '[x] Cannot detect OS.' >&2; exit 1; }
case "${ID:-}" in ubuntu|debian) ;; *) echo '[x] Ubuntu/Debian only.' >&2; exit 1;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl ca-certificates python3 openssh-client >/dev/null

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "${RAW}/dual-control-panel/dualctl" -o "$TMP"
bash -n "$TMP"
install -m 0755 "$TMP" "$BIN"

cat > /usr/local/bin/dual-panel <<'EOFLINK'
#!/usr/bin/env bash
exec /usr/local/bin/dualctl "$@"
EOFLINK
chmod 0755 /usr/local/bin/dual-panel

valid_ipv4(){
  local ip="$1" IFS=. a o
  read -r -a a <<< "$ip"
  [[ ${#a[@]} -eq 4 ]] || return 1
  for o in "${a[@]}"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && ((10#$o<=255)) || return 1; done
}
ask_ip(){
  local prompt="$1" default="$2" v
  while :; do
    read -r -p "$prompt [$default]: " v; v="${v:-$default}"
    valid_ipv4 "$v" && { printf '%s' "$v"; return; }
    echo 'Invalid IPv4.' >&2
  done
}

import_existing(){
  [[ ! -f "$STATE_FILE" ]] || return 0
  [[ -f /etc/dual-backhaul-ha/role ]] || return 0
  local role bundle IRAN_IP FOREIGN_A_IP FOREIGN_B_IP DOMAIN_A DOMAIN_B FOREIGN_ROLE BUNDLE_PATH
  role="$(cat /etc/dual-backhaul-ha/role 2>/dev/null || true)"
  install -d -m 0700 "$STATE_DIR"
  umask 077

  if [[ "$role" == iran && -f /etc/dual-backhaul-ha/topology.env ]]; then
    # shellcheck disable=SC1091
    source /etc/dual-backhaul-ha/topology.env
    echo
    echo '[i] Existing Dual Iran installation detected.'
    echo '[i] Import only: no Backhaul/HAProxy service will be reinstalled.'
    echo '[i] Confirm the CURRENT live IPs (important after a Foreign replacement).'
    IRAN_IP="$(ask_ip 'Iran IPv4' "${IRAN_IP:-$(hostname -I | awk '{print $1}')}" )"
    FOREIGN_A_IP="$(ask_ip 'Current Foreign A IPv4' "${FOREIGN_A_IP:-127.0.0.1}")"
    FOREIGN_B_IP="$(ask_ip 'Current Foreign B IPv4' "${FOREIGN_B_IP:-127.0.0.1}")"
    read -r -p "Domain A [${DOMAIN_A:-}]: " x; DOMAIN_A="${x:-${DOMAIN_A:-}}"
    read -r -p "Domain B [${DOMAIN_B:-}]: " x; DOMAIN_B="${x:-${DOMAIN_B:-}}"
    cat > "$STATE_FILE" <<EOFSTATE
ROLE='iran'
IRAN_IP='${IRAN_IP}'
FOREIGN_A_IP='${FOREIGN_A_IP}'
FOREIGN_B_IP='${FOREIGN_B_IP}'
DOMAIN_A='${DOMAIN_A}'
DOMAIN_B='${DOMAIN_B}'
WSS_ENABLED='1'
FOREIGN_ROLE=''
BUNDLE_PATH=''
EOFSTATE
    chmod 0600 "$STATE_FILE"
    echo '[+] Existing Iran installation imported into panel state.'
    return 0
  fi

  if [[ "$role" == foreign-a || "$role" == foreign-b ]]; then
    bundle=/etc/dual-backhaul-ha/bundle.env
    [[ -f "$bundle" ]] || return 0
    IRAN_IP="$(sed -n "s/^IRAN_IP='\([^']*\)'$/\1/p" "$bundle" | head -n1)"
    foreign_ip="$(sed -n "s/^FOREIGN_IP='\([^']*\)'$/\1/p" "$bundle" | head -n1)"
    domain="$(sed -n "s/^DOMAIN='\([^']*\)'$/\1/p" "$bundle" | head -n1)"
    if [[ "$role" == foreign-a ]]; then FOREIGN_A_IP="$foreign_ip"; FOREIGN_B_IP=''; DOMAIN_A="$domain"; DOMAIN_B=''; else FOREIGN_B_IP="$foreign_ip"; FOREIGN_A_IP=''; DOMAIN_B="$domain"; DOMAIN_A=''; fi
    cat > "$STATE_FILE" <<EOFSTATE
ROLE='foreign'
IRAN_IP='${IRAN_IP}'
FOREIGN_A_IP='${FOREIGN_A_IP}'
FOREIGN_B_IP='${FOREIGN_B_IP}'
DOMAIN_A='${DOMAIN_A}'
DOMAIN_B='${DOMAIN_B}'
WSS_ENABLED='1'
FOREIGN_ROLE='${role}'
BUNDLE_PATH='${bundle}'
EOFSTATE
    chmod 0600 "$STATE_FILE"
    echo "[+] Existing ${role} installation imported into panel state."
  fi
}

import_existing

echo '[+] Dual-Foreign Control Panel installed.'
echo '[+] Command: dualctl'
echo
exec "$BIN"
