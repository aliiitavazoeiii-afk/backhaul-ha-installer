#!/usr/bin/env bash
set -Eeuo pipefail

VERSION='v2.9.4'
BASE='https://github.com/MHSanaei/3x-ui/releases/download/v2.9.4'
TAG_RAW='https://raw.githubusercontent.com/MHSanaei/3x-ui/v2.9.4'
DB='/etc/x-ui/x-ui.db'
TEMPLATE='/root/aegis-xui-template.db'
BACKUP_DIR='/root/aegis-xui-backups'
MARKER='/etc/aegis-control/xui-version'

log(){ printf '[xui] %s\n' "$*"; }
die(){ printf '[xui][FAIL] %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'
command -v systemctl >/dev/null || die 'systemd is required'

case "$(uname -m)" in
  x86_64|amd64)
    ASSET='x-ui-linux-amd64.tar.gz'
    SHA256='ffff36ba6750b62e54bba3ec771e003d2bded9bbda30ae0d960d5599235d4ee7'
    XRAY_ARCH='amd64'
    ;;
  aarch64|arm64)
    ASSET='x-ui-linux-arm64.tar.gz'
    SHA256='5dbf2abdbe8199acf1d3684ed8d0dce337336a5bd12d903273b690ed48e11b29'
    XRAY_ARCH='arm64'
    ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null; then
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates tar sqlite3 openssl >/dev/null
else
  die 'this production installer currently supports Debian/Ubuntu hosts only'
fi

install -d -m 0700 "$BACKUP_DIR"
install -d -m 0755 /etc/x-ui /etc/aegis-control /var/log/x-ui
if [[ -s "$DB" ]]; then
  sqlite3 "$DB" ".backup '${BACKUP_DIR}/x-ui.db.$(date +%Y%m%d-%H%M%S)'" || cp -a "$DB" "${BACKUP_DIR}/x-ui.db.raw.$(date +%Y%m%d-%H%M%S)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -4fL --retry 3 --connect-timeout 10 "${BASE}/${ASSET}" -o "$TMP/$ASSET"
printf '%s  %s\n' "$SHA256" "$TMP/$ASSET" | sha256sum -c - >/dev/null || die '3x-ui release SHA256 mismatch'
tar -xzf "$TMP/$ASSET" -C "$TMP"
[[ -x "$TMP/x-ui/x-ui" ]] || die 'release archive does not contain x-ui binary'

systemctl stop x-ui >/dev/null 2>&1 || true
rm -rf /usr/local/x-ui.new
mv "$TMP/x-ui" /usr/local/x-ui.new
chmod +x /usr/local/x-ui.new/x-ui /usr/local/x-ui.new/x-ui.sh
[[ -e "/usr/local/x-ui.new/bin/xray-linux-${XRAY_ARCH}" ]] && chmod +x "/usr/local/x-ui.new/bin/xray-linux-${XRAY_ARCH}"
rm -rf /usr/local/x-ui.old
[[ -d /usr/local/x-ui ]] && mv /usr/local/x-ui /usr/local/x-ui.old
mv /usr/local/x-ui.new /usr/local/x-ui

# Use service/CLI files from the same immutable v2.9.4 tag.
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

if [[ -s "$TEMPLATE" ]]; then
  log 'restoring golden x-ui database template'
  sqlite3 "$TEMPLATE" 'PRAGMA quick_check;' | grep -qx 'ok' || die 'golden template failed SQLite quick_check'
  install -m 0600 "$TEMPLATE" "$DB"
fi

systemctl daemon-reload
systemctl enable x-ui >/dev/null
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui || {
  journalctl -u x-ui -n 40 --no-pager || true
  die 'x-ui service failed to start'
}

# If this is a brand-new empty DB, secure the panel with random credentials.
if [[ ! -s "$TEMPLATE" ]]; then
  SHOW="$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null || true)"
  if grep -q 'hasDefaultCredential: true' <<<"$SHOW"; then
    USER="aegis$(openssl rand -hex 4)"
    PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
    PORT="$(shuf -i 20000-60000 -n 1)"
    PATHV="aegis$(openssl rand -hex 8)"
    /usr/local/x-ui/x-ui setting -username "$USER" -password "$PASS" -port "$PORT" -webBasePath "$PATHV" >/dev/null
    systemctl restart x-ui
    install -d -m 0700 /root/aegis-xui-credentials
    cat > /root/aegis-xui-credentials/panel.txt <<CREDS
username=$USER
password=$PASS
port=$PORT
webBasePath=$PATHV
CREDS
    chmod 0600 /root/aegis-xui-credentials/panel.txt
  fi
fi

printf '%s\n' "$VERSION" > "$MARKER"
chmod 0644 "$MARKER"

sqlite3 "$DB" 'PRAGMA quick_check;' | grep -qx 'ok' || die 'installed x-ui database failed SQLite quick_check'
log "3x-ui ${VERSION} installed and active"
if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1; then
  log 'Xray local inbound 127.0.0.1:443 is UP'
else
  log 'Xray local inbound 127.0.0.1:443 is NOT UP; Aegis provisioning must not continue without a valid golden template/inbound'
  exit 20
fi
