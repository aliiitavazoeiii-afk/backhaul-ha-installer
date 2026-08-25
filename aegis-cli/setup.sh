#!/usr/bin/env bash
set -Eeuo pipefail

VERSION='2.0.0'
AEGIS_PIN='ef0e8a44065ca537c976858c9f9ae8f7a503313c'
BACKUP_PIN='2be6343fb6af4e99d5c019eaf698e06047388b73'
REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
STATE_DIR='/etc/aegis-cli'
RESULT_FILE='/root/aegis-setup-result.txt'
SSH_KEY='/root/.ssh/id_ed25519'
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new)

log(){ printf '\n\033[1;34m[+]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this installer as root on the IRAN gateway.'
command -v apt-get >/dev/null || die 'Ubuntu/Debian is required on the IRAN gateway.'

valid_ip(){
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    x = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if x.version == 4 else 1)
PY
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

retry_cmd(){
    local attempts="$1" delay="$2"; shift 2
    local n=1 rc=0
    while (( n <= attempts )); do
        if "$@"; then
            return 0
        else
            rc=$?
        fi
        (( n == attempts )) && return "$rc"
        warn "Attempt $n/$attempts failed; retrying in ${delay}s"
        sleep "$delay"
        ((n++))
    done
    return "$rc"
}

cleanup_old_dashboard(){
    if systemctl list-unit-files 2>/dev/null | grep -q '^aegis-dashboard.service'; then
        systemctl disable --now aegis-dashboard >/dev/null 2>&1 || true
    fi
    rm -f /etc/nginx/conf.d/aegis-dashboard-public.conf
    rm -f /etc/letsencrypt/renewal-hooks/deploy/aegis-dashboard-public
    rm -rf /etc/systemd/system/aegis-dashboard.service.d
    rm -f /etc/aegis-dashboard/public.env
    systemctl daemon-reload >/dev/null 2>&1 || true
}

detect_iran_ip(){
    local detected
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [[ -n "$detected" ]] || detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
    valid_ip "$detected" || return 1
    printf '%s' "$detected"
}

ensure_local_deps(){
    log 'Installing small prerequisites on IRAN'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates openssh-client sshpass python3 >/dev/null
}

ensure_ssh_key(){
    install -d -m 0700 /root/.ssh
    if [[ -s "$SSH_KEY" ]]; then
        if [[ ! -s "${SSH_KEY}.pub" ]]; then
            ssh-keygen -y -f "$SSH_KEY" > "${SSH_KEY}.pub"
            chmod 0644 "${SSH_KEY}.pub"
        fi
        return
    fi
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"
}

ssh_ready(){ ssh "${SSH_OPTS[@]}" "root@$1" true >/dev/null 2>&1; }

check_hostkey_conflict(){
    local host="$1" out rc
    set +e
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "root@$host" true 2>&1)"
    rc=$?
    set -e
    if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' <<<"$out"; then
        printf '%s\n' "$out" >&2
        die "SSH host key for $host changed. Verify the VPS first, then run: ssh-keygen -f /root/.ssh/known_hosts -R $host"
    fi
    return "$rc"
}

bootstrap_ssh(){
    local host="$1" label="$2" pw
    if retry_cmd 3 2 ssh_ready "$host"; then
        ok "$label SSH key already works"
        return
    fi
    check_hostkey_conflict "$host" || true
    printf '\nRoot password for %s (%s) [used once, not saved]: ' "$label" "$host"
    read -rs pw
    printf '\n'
    [[ -n "$pw" ]] || die "Empty password for $label"
    export SSHPASS="$pw"
    if ! retry_cmd 3 2 sshpass -e ssh-copy-id -i "${SSH_KEY}.pub" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$host" >/dev/null; then
        unset SSHPASS pw
        die "Could not install the SSH key on $label $host. Check root SSH access."
    fi
    unset SSHPASS pw
    retry_cmd 3 2 ssh_ready "$host" || die "SSH key bootstrap failed for $label $host"
    ok "$label SSH key installed"
}

ssh_retry(){ retry_cmd 4 3 ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
scp_retry(){
    local src="$1" host="$2" dst="$3"
    retry_cmd 4 3 scp "${SSH_OPTS[@]}" "$src" "root@$host:$dst"
}

foreign_xray_ready(){
    local host="$1"
    ssh_retry "$host" "systemctl is-active --quiet x-ui && timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443'" >/dev/null 2>&1
}

require_foreign_xui(){
    local host="$1" label="$2"
    if foreign_xray_ready "$host"; then
        ok "$label: x-ui active and Xray reachable on 127.0.0.1:443"
        return
    fi
    die "$label $host is not ready. Install/manage 3x-ui yourself, start x-ui, and create the production inbound on TCP :443 so it is reachable via 127.0.0.1:443; then re-run this installer. This installer never installs or modifies 3x-ui."
}

backup_existing_relay_ready(){
    local host="$1" ip="$2"
    ssh_retry "$host" "
      systemctl is-active --quiet x-ui &&
      timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' &&
      systemctl is-active --quiet aegis-backup-watchdog.timer &&
      systemctl is-active --quiet aegis-direct-backup.socket &&
      ss -Hlnpt '( sport = :443 )' 2>/dev/null | grep -Fq '$ip:443'
    " >/dev/null 2>&1
}

ensure_backup_firewall(){
    ssh_retry "$BACKUP_IP" "if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow from '$IRAN_IP' to any port 443 proto tcp >/dev/null || true; fi" >/dev/null
}

iran_can_reach_backup(){
    timeout 5 bash -c "exec 3<>/dev/tcp/$BACKUP_IP/443" >/dev/null 2>&1
}

wait_primary_ready(){
    local n
    for n in {1..20}; do
        if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/10444' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

download_installers(){
    install -d -m 0700 "$STATE_DIR"
    AEGIS_INSTALLER="$STATE_DIR/install-aegis-single.sh"
    BACKUP_INSTALLER="$STATE_DIR/add-direct-backup.sh"

    log 'Downloading immutable tested Aegis installers'
    curl -fL --retry 4 --connect-timeout 10 "https://raw.githubusercontent.com/${REPO}/${AEGIS_PIN}/aegis-single/install.sh" -o "$AEGIS_INSTALLER"
    curl -fL --retry 4 --connect-timeout 10 "https://raw.githubusercontent.com/${REPO}/${BACKUP_PIN}/aegis-single/add-direct-backup.sh" -o "$BACKUP_INSTALLER"
    bash -n "$AEGIS_INSTALLER"
    bash -n "$BACKUP_INSTALLER"
    chmod 0700 "$AEGIS_INSTALLER" "$BACKUP_INSTALLER"
}

install_iran_primary(){
    log 'Installing Aegis gateway on IRAN'
    bash "$AEGIS_INSTALLER" --role iran --iran-ip "$IRAN_IP" --domain "$DOMAIN"
    [[ -s /root/aegis-primary.env ]] || die 'Aegis primary bundle was not created on IRAN.'

    log 'Installing Aegis client on PRIMARY (3x-ui is preserved)'
    scp_retry "$AEGIS_INSTALLER" "$PRIMARY_IP" /root/install-aegis-single.sh
    scp_retry /root/aegis-primary.env "$PRIMARY_IP" /root/aegis-primary.env
    ssh_retry "$PRIMARY_IP" "chmod 700 /root/install-aegis-single.sh && bash /root/install-aegis-single.sh --role foreign --bundle /root/aegis-primary.env"
}

install_backup_path(){
    log 'Preparing direct BACKUP path'
    if backup_existing_relay_ready "$BACKUP_IP" "$BACKUP_IP"; then
        ok 'Existing Aegis backup relay detected; reusing it'
    else
        scp_retry "$BACKUP_INSTALLER" "$BACKUP_IP" /root/add-direct-backup.sh
        ssh_retry "$BACKUP_IP" "chmod 700 /root/add-direct-backup.sh && bash /root/add-direct-backup.sh --role foreign --iran-ip '$IRAN_IP' --backup-ip '$BACKUP_IP'"
    fi

    ensure_backup_firewall
    retry_cmd 5 2 iran_can_reach_backup || die "IRAN cannot reach BACKUP $BACKUP_IP:443 after setup."

    log 'Adding BACKUP to IRAN HAProxy as true standby'
    bash "$BACKUP_INSTALLER" --role iran --iran-ip "$IRAN_IP" --backup-ip "$BACKUP_IP"
}

final_validate(){
    log 'Running final validation'
    local primary_ok=0

    systemctl is-active --quiet aegis-server || die 'aegis-server is not active on IRAN.'
    systemctl is-active --quiet nginx || die 'nginx is not active on IRAN.'
    systemctl is-active --quiet haproxy || die 'haproxy is not active on IRAN.'
    foreign_xray_ready "$PRIMARY_IP" || die 'PRIMARY x-ui/Xray local :443 is not healthy.'
    foreign_xray_ready "$BACKUP_IP" || die 'BACKUP x-ui/Xray local :443 is not healthy.'
    retry_cmd 3 2 iran_can_reach_backup || die 'Direct BACKUP :443 is not reachable from IRAN.'
    grep -A8 '^backend user_gateway$' /etc/haproxy/haproxy.cfg | grep -Eq "server[[:space:]]+direct_backup[[:space:]]+$BACKUP_IP:443.*[[:space:]]backup([[:space:]]|$)" || die 'HAProxy direct_backup line is missing or is not standby-only.'

    if wait_primary_ready; then
        primary_ok=1
    fi

    aegisctl status || true
    if (( primary_ok == 0 )); then
        die 'BACKUP is installed, but PRIMARY Aegis readiness is DOWN. Check PRIMARY network/carrier before calling this deployment complete.'
    fi

    ok 'PRIMARY Aegis path is UP'
    ok 'BACKUP direct path is reachable and standby-only'
    ok '3x-ui/Xray is healthy on both Foreign servers and was not modified by this installer'
}

save_result(){
    install -d -m 0700 "$STATE_DIR"
    cat > "$STATE_DIR/config.env" <<EOFSTATE
DOMAIN='$DOMAIN'
IRAN_IP='$IRAN_IP'
PRIMARY_IP='$PRIMARY_IP'
BACKUP_IP='$BACKUP_IP'
EOFSTATE
    chmod 0600 "$STATE_DIR/config.env"

    cat > "$RESULT_FILE" <<EOFRESULT
Aegis tunnel-only setup $VERSION
Domain: $DOMAIN
Iran: $IRAN_IP
Primary: $PRIMARY_IP
Backup: $BACKUP_IP

Normal path: User -> Iran -> Aegis -> Primary
Failover path: User reconnect -> Iran -> Direct Backup

3x-ui ownership: manual/user-managed on both Foreign servers.
This installer does not install, clone, sync, reset, or modify 3x-ui.
Keep the required production users/inbounds present on both Foreign servers.
EOFRESULT
    chmod 0600 "$RESULT_FILE"
}

main(){
    ensure_local_deps
    IRAN_IP="$(detect_iran_ip)" || die 'Could not detect the IRAN IPv4 automatically.'

    printf '\n===============================================\n'
    printf ' Aegis Tunnel-Only Setup %s\n' "$VERSION"
    printf ' Detected IRAN IPv4: %s\n' "$IRAN_IP"
    printf ' 3x-ui: user-managed; installer will NOT touch it\n'
    printf '===============================================\n\n'

    read -rp 'Aegis domain (A record -> this IRAN IP): ' DOMAIN
    read -rp 'Foreign PRIMARY IPv4: ' PRIMARY_IP
    read -rp 'Foreign BACKUP IPv4: ' BACKUP_IP

    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"
    valid_domain "$DOMAIN" || die 'Invalid domain.'
    valid_ip "$PRIMARY_IP" || die 'Invalid PRIMARY IPv4.'
    valid_ip "$BACKUP_IP" || die 'Invalid BACKUP IPv4.'
    [[ "$IRAN_IP" != "$PRIMARY_IP" && "$IRAN_IP" != "$BACKUP_IP" && "$PRIMARY_IP" != "$BACKUP_IP" ]] || die 'Iran, Primary and Backup IPs must all be different.'

    mapfile -t DNS_IPS < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${DNS_IPS[@]:-}" | grep -Fxq "$IRAN_IP" || die "$DOMAIN does not resolve to detected IRAN IP $IRAN_IP. Current IPv4 results: ${DNS_IPS[*]:-none}"
    ok "DNS: $DOMAIN -> $IRAN_IP"

    printf '\nAbout to provision:\n  IRAN    %s\n  PRIMARY %s\n  BACKUP  %s\n  DOMAIN  %s\n' "$IRAN_IP" "$PRIMARY_IP" "$BACKUP_IP" "$DOMAIN"
    printf '\nPrerequisite: x-ui must already be installed by you on both Foreign servers, with the production TCP :443 inbound reachable from localhost.\n'
    read -rp 'Continue? [y/N]: ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || die 'Cancelled; no provisioning started.'

    cleanup_old_dashboard
    ensure_ssh_key
    bootstrap_ssh "$PRIMARY_IP" 'PRIMARY'
    bootstrap_ssh "$BACKUP_IP" 'BACKUP'

    log 'Checking user-managed 3x-ui prerequisites'
    require_foreign_xui "$PRIMARY_IP" 'PRIMARY'
    require_foreign_xui "$BACKUP_IP" 'BACKUP'

    download_installers
    install_iran_primary
    install_backup_path
    final_validate
    save_result

    printf '\n===============================================\n'
    printf '\033[1;32m SUCCESS - PRODUCTION TOPOLOGY VERIFIED \033[0m\n'
    printf '===============================================\n'
    printf 'Iran:    %s\n' "$IRAN_IP"
    printf 'Primary: %s  (Aegis normal path)\n' "$PRIMARY_IP"
    printf 'Backup:  %s  (direct standby only)\n' "$BACKUP_IP"
    printf 'Domain:  %s\n' "$DOMAIN"
    printf '\n3x-ui was not installed or modified.\n'
    printf 'Saved summary: %s\n' "$RESULT_FILE"
}

main "$@"
