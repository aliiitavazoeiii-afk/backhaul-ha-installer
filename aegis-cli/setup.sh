#!/usr/bin/env bash
set -Eeuo pipefail

VERSION='1.0.1'
AEGIS_PIN='ef0e8a44065ca537c976858c9f9ae8f7a503313c'
BACKUP_PIN='2be6343fb6af4e99d5c019eaf698e06047388b73'
REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
STATE_DIR='/etc/aegis-cli'
RESULT_FILE='/root/aegis-setup-result.txt'
PRIMARY_CREDS_LOCAL='/root/aegis-primary-credentials.txt'
SSH_KEY='/root/.ssh/id_ed25519'
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new)

log(){ printf '\n\033[1;34m[+]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this wizard as root on the IRAN gateway.'
command -v apt-get >/dev/null || die 'This wizard currently supports Ubuntu/Debian on the IRAN gateway.'

valid_ip(){ python3 - "$1" <<'PY'
import ipaddress,sys
try:
    x=ipaddress.ip_address(sys.argv[1]); raise SystemExit(0 if x.version==4 else 1)
except ValueError: raise SystemExit(1)
PY
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

cleanup_old_dashboard(){
    if systemctl list-unit-files 2>/dev/null | grep -q '^aegis-dashboard.service'; then
        log 'Removing the old custom Aegis web dashboard'
        systemctl disable --now aegis-dashboard >/dev/null 2>&1 || true
    fi
    rm -f /etc/nginx/conf.d/aegis-dashboard-public.conf
    rm -f /etc/letsencrypt/renewal-hooks/deploy/aegis-dashboard-public
    rm -rf /etc/systemd/system/aegis-dashboard.service.d
    rm -f /etc/aegis-dashboard/public.env
    systemctl daemon-reload >/dev/null 2>&1 || true
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
    fi
}

detect_iran_ip(){
    local detected
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [[ -n "$detected" ]] || detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
    valid_ip "$detected" || return 1
    printf '%s' "$detected"
}

ensure_local_deps(){
    log 'Installing small local prerequisites'
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
        die "SSH host key for $host changed. Verify the VPS in your provider console, then run: ssh-keygen -f /root/.ssh/known_hosts -R $host"
    fi
    return "$rc"
}

bootstrap_ssh(){
    local host="$1" label="$2" pw
    ssh_ready "$host" && { ok "$label SSH key already works"; return; }
    check_hostkey_conflict "$host" || true
    printf '\nRoot password for %s (%s) [used once, not saved]: ' "$label" "$host"
    read -rs pw
    printf '\n'
    [[ -n "$pw" ]] || die "Empty password for $label"
    export SSHPASS="$pw"
    if ! sshpass -e ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=accept-new "root@$host" >/dev/null; then
        unset SSHPASS pw
        die "Could not install the SSH key on $label $host. Check its root password / SSH policy."
    fi
    unset SSHPASS pw
    ssh_ready "$host" || die "SSH key bootstrap failed for $label $host"
    ok "$label SSH key installed"
}

remote_xui_script(){
cat <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
MODE="${1:?mode}"
TEMPLATE="${2:-}"
VERSION='2.9.4'
BASE='https://github.com/MHSanaei/3x-ui/releases/download/v2.9.4'
TAG_RAW='https://raw.githubusercontent.com/MHSanaei/3x-ui/v2.9.4'
DB='/etc/x-ui/x-ui.db'
BACKUP_DIR='/root/aegis-xui-backups'
CREDS_DIR='/root/aegis-xui-credentials'
CREDS_FILE="$CREDS_DIR/panel.txt"

log(){ printf '[xui] %s\n' "$*"; }
die(){ printf '[xui][FAIL] %s\n' "$*" >&2; exit 1; }
json_success(){
    python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("success") is True else 1)'
}

case "$(uname -m)" in
  x86_64|amd64) ASSET='x-ui-linux-amd64.tar.gz'; SHA256='ffff36ba6750b62e54bba3ec771e003d2bded9bbda30ae0d960d5599235d4ee7'; XRAY_ARCH='amd64' ;;
  aarch64|arm64) ASSET='x-ui-linux-arm64.tar.gz'; SHA256='5dbf2abdbe8199acf1d3684ed8d0dce337336a5bd12d903273b690ed48e11b29'; XRAY_ARCH='arm64' ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

export DEBIAN_FRONTEND=noninteractive
command -v apt-get >/dev/null || die 'Ubuntu/Debian required on Foreign servers'
apt-get update -y >/dev/null
apt-get install -y curl ca-certificates tar sqlite3 openssl python3 >/dev/null
install -d -m 0700 "$BACKUP_DIR" "$CREDS_DIR"
install -d -m 0755 /etc/x-ui /var/log/x-ui

existing_ver=''
if [[ -x /usr/local/x-ui/x-ui ]]; then
    existing_ver="$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [[ -n "$existing_ver" && "$existing_ver" != "$VERSION" ]]; then
    die "existing 3x-ui version is $existing_ver; refusing automatic replacement with $VERSION"
fi

install_binary(){ (
    set -Eeuo pipefail
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -4fL --retry 3 --connect-timeout 10 "${BASE}/${ASSET}" -o "$tmp/$ASSET"
    printf '%s  %s\n' "$SHA256" "$tmp/$ASSET" | sha256sum -c - >/dev/null || die '3x-ui release SHA256 mismatch'
    tar -xzf "$tmp/$ASSET" -C "$tmp"
    [[ -x "$tmp/x-ui/x-ui" ]] || die 'release archive missing x-ui binary'
    systemctl stop x-ui >/dev/null 2>&1 || true
    rm -rf /usr/local/x-ui.new
    mv "$tmp/x-ui" /usr/local/x-ui.new
    chmod +x /usr/local/x-ui.new/x-ui /usr/local/x-ui.new/x-ui.sh
    [[ -e "/usr/local/x-ui.new/bin/xray-linux-${XRAY_ARCH}" ]] && chmod +x "/usr/local/x-ui.new/bin/xray-linux-${XRAY_ARCH}"
    rm -rf /usr/local/x-ui.old
    [[ -d /usr/local/x-ui ]] && mv /usr/local/x-ui /usr/local/x-ui.old
    mv /usr/local/x-ui.new /usr/local/x-ui
    if [[ -f /usr/local/x-ui/x-ui.service ]]; then
        cp -f /usr/local/x-ui/x-ui.service /etc/systemd/system/x-ui.service
    elif [[ -f /usr/local/x-ui/x-ui.service.debian ]]; then
        cp -f /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
    else
        curl -4fL --retry 3 "${TAG_RAW}/x-ui.service.debian" -o /etc/systemd/system/x-ui.service
    fi
    if [[ -f /usr/local/x-ui/x-ui.sh ]]; then
        cp -f /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    else
        curl -4fL --retry 3 "${TAG_RAW}/x-ui.sh" -o /usr/bin/x-ui
    fi
    chmod 0755 /usr/bin/x-ui
    chmod 0644 /etc/systemd/system/x-ui.service
    systemctl daemon-reload
); }

if [[ "$existing_ver" != "$VERSION" ]]; then
    log "installing verified 3x-ui $VERSION"
    install_binary
fi

if [[ "$MODE" == 'backup' ]]; then
    [[ -s "$TEMPLATE" ]] || die 'primary DB snapshot missing on backup'
    sqlite3 "$TEMPLATE" 'PRAGMA quick_check;' | grep -qx ok || die 'primary DB snapshot is not healthy'
    if [[ -s "$DB" ]]; then
        sqlite3 "$DB" ".backup '${BACKUP_DIR}/x-ui.db.$(date +%Y%m%d-%H%M%S)'" || cp -a "$DB" "${BACKUP_DIR}/x-ui.db.raw.$(date +%Y%m%d-%H%M%S)"
    fi
    systemctl stop x-ui >/dev/null 2>&1 || true
    install -m 0600 "$TEMPLATE" "$DB"
    WEB_CERT="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='webCertFile' LIMIT 1;" 2>/dev/null || true)"
    WEB_KEY="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='webKeyFile' LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$WEB_CERT" || -n "$WEB_KEY" ]]; then
        if [[ -z "$WEB_CERT" || -z "$WEB_KEY" || ! -s "$WEB_CERT" || ! -s "$WEB_KEY" ]]; then
            /usr/local/x-ui/x-ui cert -reset true >/dev/null 2>&1 || true
        fi
    fi
    systemctl enable x-ui >/dev/null
    systemctl restart x-ui
    sleep 4
    systemctl is-active --quiet x-ui || { journalctl -u x-ui -n 50 --no-pager || true; die 'x-ui failed after restoring primary DB'; }
    timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1 || die 'restored backup does not expose Xray on 127.0.0.1:443'
    log 'backup 3x-ui matches primary DB and Xray :443 is UP'
    exit 0
fi

# Preserve an already-healthy primary exactly as-is.
if [[ -s "$DB" ]] && systemctl is-active --quiet x-ui 2>/dev/null && timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1; then
    sqlite3 "$DB" 'PRAGMA quick_check;' | grep -qx ok || die 'existing primary x-ui DB failed quick_check'
    log 'existing primary 3x-ui v2.9.4 + Xray :443 is healthy; preserving it'
    exit 0
fi

# Fresh or incomplete v2.9.4 primary: back up its DB, secure the panel locally,
# then create a minimal VLESS/TCP inbound on localhost:443 through the v2.9.4 API.
if [[ -s "$DB" ]]; then
    sqlite3 "$DB" ".backup '${BACKUP_DIR}/x-ui.db.$(date +%Y%m%d-%H%M%S)'" || cp -a "$DB" "${BACKUP_DIR}/x-ui.db.raw.$(date +%Y%m%d-%H%M%S)"
fi
USER="aegis$(openssl rand -hex 4)"
PASS="$(openssl rand -hex 16)"
PORT="$(shuf -i 20000-60000 -n 1)"
PATHV="aegis$(openssl rand -hex 8)"
/usr/local/x-ui/x-ui setting -username "$USER" -password "$PASS" -port "$PORT" -webBasePath "$PATHV" -listenIP '127.0.0.1' >/dev/null
systemctl enable x-ui >/dev/null
systemctl restart x-ui
sleep 4
systemctl is-active --quiet x-ui || { journalctl -u x-ui -n 50 --no-pager || true; die 'fresh x-ui service failed to start'; }

UUID="$(cat /proc/sys/kernel/random/uuid)"
SUBID="$(openssl rand -hex 8)"
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
LOGIN="http://127.0.0.1:${PORT}/${PATHV}/login"
API="http://127.0.0.1:${PORT}/${PATHV}/panel/api/inbounds/add"
LOGIN_RESP="$(curl -sS --connect-timeout 5 --max-time 15 -c "$COOKIE" -X POST --data-urlencode "username=${USER}" --data-urlencode "password=${PASS}" "$LOGIN" || true)"
printf '%s' "$LOGIN_RESP" | json_success || { printf '%s\n' "$LOGIN_RESP" >&2; die 'could not authenticate to fresh local 3x-ui panel'; }
SETTINGS="{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"\",\"email\":\"aegis-bootstrap\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":0,\"subId\":\"${SUBID}\",\"reset\":0}],\"decryption\":\"none\",\"fallbacks\":[]}"
STREAM='{"network":"tcp","security":"none","externalProxy":[],"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
SNIFF='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
PAYLOAD="$(python3 - "$SETTINGS" "$STREAM" "$SNIFF" <<'PY'
import json,sys
print(json.dumps({
    'up':0,'down':0,'total':0,'allTime':0,'remark':'aegis-bootstrap','enable':True,
    'expiryTime':0,'trafficReset':'never','lastTrafficResetTime':0,
    'listen':'127.0.0.1','port':443,'protocol':'vless',
    'settings':sys.argv[1],'streamSettings':sys.argv[2],'sniffing':sys.argv[3]
}, separators=(',',':')))
PY
)"
RESP="$(curl -sS --connect-timeout 5 --max-time 20 -b "$COOKIE" -H 'Content-Type: application/json' -X POST --data-binary "$PAYLOAD" "$API" || true)"
printf '%s' "$RESP" | json_success || { printf '%s\n' "$RESP" >&2; die '3x-ui rejected the bootstrap inbound'; }
systemctl restart x-ui
sleep 5
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1 || { journalctl -u x-ui -n 50 --no-pager || true; die 'bootstrap Xray inbound 127.0.0.1:443 did not come UP'; }
sqlite3 "$DB" 'PRAGMA quick_check;' | grep -qx ok || die 'fresh primary x-ui DB failed quick_check'
cat > "$CREDS_FILE" <<EOF
panel_listen=127.0.0.1
panel_port=$PORT
panel_path=/$PATHV/
panel_username=$USER
panel_password=$PASS
bootstrap_vless_uuid=$UUID
bootstrap_sub_id=$SUBID
EOF
chmod 0600 "$CREDS_FILE"
log 'fresh primary 3x-ui v2.9.4 + bootstrap Xray :443 is UP'
REMOTE
}

run_remote_xui(){
    local host="$1" mode="$2" template_remote="${3:-}"
    remote_xui_script | ssh "${SSH_OPTS[@]}" "root@$host" "bash -s -- '$mode' '$template_remote'"
}

capture_primary_db(){
    local tmp='/root/aegis-primary-xui.db'
    log 'Taking a one-time healthy 3x-ui snapshot from PRIMARY'
    ssh "${SSH_OPTS[@]}" "root@$PRIMARY_IP" "command -v sqlite3 >/dev/null; test -s /etc/x-ui/x-ui.db; rm -f /root/aegis-primary-xui.db; sqlite3 /etc/x-ui/x-ui.db \".backup '/root/aegis-primary-xui.db'\"; sqlite3 /root/aegis-primary-xui.db 'PRAGMA quick_check;' | grep -qx ok"
    scp "${SSH_OPTS[@]}" "root@$PRIMARY_IP:/root/aegis-primary-xui.db" "$tmp" >/dev/null
    python3 - "$tmp" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); r=c.execute('PRAGMA quick_check').fetchone(); c.close()
raise SystemExit(0 if r and r[0]=='ok' else 1)
PY
    ok 'Primary DB snapshot is healthy'

    rm -f "$PRIMARY_CREDS_LOCAL"
    if ssh "${SSH_OPTS[@]}" "root@$PRIMARY_IP" 'test -s /root/aegis-xui-credentials/panel.txt' >/dev/null 2>&1; then
        scp "${SSH_OPTS[@]}" "root@$PRIMARY_IP:/root/aegis-xui-credentials/panel.txt" "$PRIMARY_CREDS_LOCAL" >/dev/null
        chmod 0600 "$PRIMARY_CREDS_LOCAL"
    fi
}

install_infra(){
    local aegis='/root/aegis-single-install.sh' backup='/root/aegis-direct-backup.sh'
    cleanup_old_dashboard
    log 'Downloading immutable tested Aegis installers'
    curl -fL --retry 3 "https://raw.githubusercontent.com/${REPO}/${AEGIS_PIN}/aegis-single/install.sh" -o "$aegis"
    curl -fL --retry 3 "https://raw.githubusercontent.com/${REPO}/${BACKUP_PIN}/aegis-single/add-direct-backup.sh" -o "$backup"
    bash -n "$aegis"; bash -n "$backup"; chmod 0700 "$aegis" "$backup"

    log 'Installing Aegis gateway on IRAN'
    bash "$aegis" --role iran --iran-ip "$IRAN_IP" --domain "$DOMAIN"
    [[ -s /root/aegis-primary.env ]] || die 'Aegis primary bundle was not created on IRAN'

    log 'Installing Aegis client on PRIMARY'
    scp "${SSH_OPTS[@]}" "$aegis" "root@$PRIMARY_IP:/root/install-aegis-single.sh" >/dev/null
    scp "${SSH_OPTS[@]}" /root/aegis-primary.env "root@$PRIMARY_IP:/root/aegis-primary.env" >/dev/null
    ssh "${SSH_OPTS[@]}" "root@$PRIMARY_IP" 'chmod 700 /root/install-aegis-single.sh && bash /root/install-aegis-single.sh --role foreign --bundle /root/aegis-primary.env'

    log 'Installing health-gated direct relay on BACKUP'
    scp "${SSH_OPTS[@]}" "$backup" "root@$BACKUP_IP:/root/add-direct-backup.sh" >/dev/null
    ssh "${SSH_OPTS[@]}" "root@$BACKUP_IP" "chmod 700 /root/add-direct-backup.sh && bash /root/add-direct-backup.sh --role foreign --iran-ip '$IRAN_IP' --backup-ip '$BACKUP_IP'"

    log 'Adding BACKUP to IRAN HAProxy as true standby'
    bash "$backup" --role iran --iran-ip "$IRAN_IP" --backup-ip "$BACKUP_IP"
}

final_validate(){
    log 'Running final end-to-end validation'
    local st
    st="$(aegisctl status)"
    printf '%s\n' "$st"
    grep -q 'aegis-server: active' <<<"$st" || die 'Aegis server is not active'
    grep -q 'haproxy:      active' <<<"$st" || die 'HAProxy is not active'
    grep -q 'primary-ready: UP' <<<"$st" || die 'Primary Aegis readiness is not UP'
    timeout 4 bash -c "exec 3<>/dev/tcp/$BACKUP_IP/443" >/dev/null 2>&1 || die 'Direct backup is not reachable from IRAN'
    ssh "${SSH_OPTS[@]}" "root@$PRIMARY_IP" "systemctl is-active --quiet x-ui && timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443'" >/dev/null || die 'PRIMARY 3x-ui/Xray :443 final check failed'
    ssh "${SSH_OPTS[@]}" "root@$BACKUP_IP" "systemctl is-active --quiet x-ui && timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443'" >/dev/null || die 'BACKUP 3x-ui/Xray :443 final check failed'
    grep -A8 '^backend user_gateway$' /etc/haproxy/haproxy.cfg | grep -q "server direct_backup $BACKUP_IP:443.* backup" || die 'HAProxy direct backup line is missing or not marked backup'
    ok 'Primary Aegis path is UP'
    ok 'Direct backup path is reachable and standby-only'
    ok '3x-ui/Xray :443 is healthy on both Foreign servers'
}

save_result(){
    install -d -m 0700 "$STATE_DIR"
    cat > "$STATE_DIR/config.env" <<EOF
DOMAIN='$DOMAIN'
IRAN_IP='$IRAN_IP'
PRIMARY_IP='$PRIMARY_IP'
BACKUP_IP='$BACKUP_IP'
EOF
    chmod 0600 "$STATE_DIR/config.env"

    local bootstrap=''
    if [[ -s "$PRIMARY_CREDS_LOCAL" ]]; then
        local uuid
        uuid="$(sed -n 's/^bootstrap_vless_uuid=//p' "$PRIMARY_CREDS_LOCAL" | head -n1)"
        if [[ -n "$uuid" ]]; then
            bootstrap="vless://${uuid}@${IRAN_IP}:443?encryption=none&security=none&type=tcp#Aegis-Bootstrap"
        fi
    fi

    {
        echo "Aegis CLI setup $VERSION"
        echo "Domain: $DOMAIN"
        echo "Iran: $IRAN_IP"
        echo "Primary: $PRIMARY_IP"
        echo "Backup: $BACKUP_IP"
        echo
        echo 'Normal path: User -> Iran -> Aegis -> Primary'
        echo 'Failover path: User reconnect -> Iran -> Direct Backup'
        if [[ -n "$bootstrap" ]]; then
            echo
            echo "Bootstrap test config: $bootstrap"
            echo "Primary 3x-ui local credentials: $PRIMARY_CREDS_LOCAL"
        fi
        echo
        echo 'No continuous user-sync is enabled.'
        echo 'Clients added after this setup must also be added to Backup if they need failover.'
    } > "$RESULT_FILE"
    chmod 0600 "$RESULT_FILE"
}

main(){
    ensure_local_deps
    IRAN_IP="$(detect_iran_ip)" || die 'Could not detect the IRAN IPv4 automatically.'

    printf '\n===============================================\n'
    printf ' Aegis Terminal Setup %s\n' "$VERSION"
    printf ' Detected IRAN IPv4: %s\n' "$IRAN_IP"
    printf '===============================================\n\n'

    read -rp 'Aegis domain (A record -> this IRAN IP): ' DOMAIN
    read -rp 'Foreign PRIMARY IPv4: ' PRIMARY_IP
    read -rp 'Foreign BACKUP IPv4: ' BACKUP_IP
    DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN%.}"
    valid_domain "$DOMAIN" || die 'Invalid domain.'
    valid_ip "$PRIMARY_IP" || die 'Invalid PRIMARY IPv4.'
    valid_ip "$BACKUP_IP" || die 'Invalid BACKUP IPv4.'
    [[ "$IRAN_IP" != "$PRIMARY_IP" && "$IRAN_IP" != "$BACKUP_IP" && "$PRIMARY_IP" != "$BACKUP_IP" ]] || die 'Iran, Primary and Backup IPs must all be different.'

    mapfile -t DNS_IPS < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "${DNS_IPS[@]:-}" | grep -Fxq "$IRAN_IP" || die "$DOMAIN does not resolve to detected IRAN IP $IRAN_IP. Current IPv4 results: ${DNS_IPS[*]:-none}"
    ok "DNS: $DOMAIN -> $IRAN_IP"

    printf '\nAbout to provision:\n  IRAN    %s\n  PRIMARY %s\n  BACKUP  %s\n  DOMAIN  %s\n' "$IRAN_IP" "$PRIMARY_IP" "$BACKUP_IP" "$DOMAIN"
    read -rp 'Continue? [y/N]: ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || die 'Cancelled; no provisioning started.'

    ensure_ssh_key
    bootstrap_ssh "$PRIMARY_IP" 'PRIMARY'
    bootstrap_ssh "$BACKUP_IP" 'BACKUP'

    log 'Preparing PRIMARY 3x-ui v2.9.4'
    run_remote_xui "$PRIMARY_IP" primary
    capture_primary_db

    log 'Preparing BACKUP 3x-ui v2.9.4 from the PRIMARY snapshot'
    scp "${SSH_OPTS[@]}" /root/aegis-primary-xui.db "root@$BACKUP_IP:/root/aegis-primary-xui.db" >/dev/null
    run_remote_xui "$BACKUP_IP" backup /root/aegis-primary-xui.db

    install_infra
    final_validate
    save_result

    printf '\n===============================================\n'
    printf '\033[1;32m SUCCESS - PRODUCTION TOPOLOGY VERIFIED \033[0m\n'
    printf '===============================================\n'
    printf 'Iran:    %s\n' "$IRAN_IP"
    printf 'Primary: %s  (Aegis normal path)\n' "$PRIMARY_IP"
    printf 'Backup:  %s  (direct standby only)\n' "$BACKUP_IP"
    printf 'Domain:  %s\n' "$DOMAIN"
    printf '\nSaved summary: %s\n' "$RESULT_FILE"
    if [[ -s "$PRIMARY_CREDS_LOCAL" ]]; then
        printf 'Fresh 3x-ui/bootstrap credentials: %s\n' "$PRIMARY_CREDS_LOCAL"
    fi
    printf '\nNo custom web dashboard is required. Re-run this wizard when replacing servers.\n'
}

main "$@"
