#!/usr/bin/env bash
set -Eeuo pipefail

NGINX_CONF=/etc/nginx/nginx.conf
OVERRIDE_DIR=/etc/systemd/system/nginx.service.d
OVERRIDE_FILE=${OVERRIDE_DIR}/frp-capacity.conf
WORKER_CONNECTIONS=65535
NOFILE=262144

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v nginx >/dev/null 2>&1 || { echo "nginx is not installed." >&2; exit 1; }
[[ -r "$NGINX_CONF" ]] || { echo "Missing $NGINX_CONF" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
cp -a "$NGINX_CONF" "${NGINX_CONF}.pre-frp-capacity-${TS}.bak"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

awk -v wc="$WORKER_CONNECTIONS" -v nf="$NOFILE" '
BEGIN { in_events=0; saw_wc=0; saw_rlimit=0 }
{
    if ($0 ~ /^[[:space:]]*worker_rlimit_nofile[[:space:]]+/) {
        if (!saw_rlimit) {
            print "worker_rlimit_nofile " nf ";"
            saw_rlimit=1
        }
        next
    }
    if ($0 ~ /^[[:space:]]*events[[:space:]]*\{/) {
        if (!saw_rlimit) {
            print "worker_rlimit_nofile " nf ";"
            print ""
            saw_rlimit=1
        }
        in_events=1
        print
        next
    }
    if (in_events && $0 ~ /^[[:space:]]*worker_connections[[:space:]]+/) {
        print "    worker_connections " wc ";"
        saw_wc=1
        next
    }
    if (in_events && $0 ~ /^[[:space:]]*\}/) {
        if (!saw_wc) {
            print "    worker_connections " wc ";"
            saw_wc=1
        }
        in_events=0
        print
        next
    }
    print
}
END {
    if (!saw_wc) exit 42
}
' "$NGINX_CONF" > "$TMP" || {
    rc=$?
    [[ $rc -eq 42 ]] && echo "Could not locate events{} in nginx.conf" >&2
    exit $rc
}

install -m 0644 "$TMP" "$NGINX_CONF"
mkdir -p "$OVERRIDE_DIR"
cat >"$OVERRIDE_FILE" <<EOF
[Service]
LimitNOFILE=${NOFILE}
EOF
chmod 0644 "$OVERRIDE_FILE"

systemctl daemon-reload
nginx -t

# Graceful reload: existing WSS/user sessions remain on old workers while new
# workers start with the larger connection table. No full nginx restart here.
systemctl reload nginx
sleep 2

nginx -t >/dev/null

echo "=== NGINX CAPACITY ==="
nginx -T 2>/dev/null | grep -E 'worker_processes|worker_rlimit_nofile|worker_connections' | head -n 10
systemctl show nginx -p LimitNOFILE

echo
echo "OK: nginx capacity raised to worker_connections=${WORKER_CONNECTIONS}, worker_rlimit_nofile=${NOFILE}."
echo "Existing connections were preserved via graceful reload."
