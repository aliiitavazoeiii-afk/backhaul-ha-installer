#!/usr/bin/env bash
set -Eeuo pipefail
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || echo unknown)"
BUNDLE=/root/backhaul-ha-secrets.env

bundle_get(){ sed -n "s/^$1='\([^']*\)'$/\1/p" "$BUNDLE" 2>/dev/null | head -1; }
bundle_set(){ local k="$1" v="$2"; sed -i "s|^${k}='[^']*'$|${k}='${v}'|" "$BUNDLE"; chmod 600 "$BUNDLE"; }
valid_ipv4(){ local IFS=. a b c d; read -r a b c d <<<"$1"; [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] && ((a<=255&&b<=255&&c<=255&&d<=255)); }
svc(){ if systemctl is-active --quiet "$1"; then printf 'OK   %s\n' "$1"; else printf 'DOWN %s\n' "$1"; fi; }

case "${1:-status}" in
  status)
    echo "Role: $ROLE"
    if [[ "$ROLE" == iran ]]; then
      svc backhaul; svc backhaul-wss; svc backhaul-tcp; svc haproxy
      command -v tunnel-diagnose >/dev/null && tunnel-diagnose || true
    elif [[ "$ROLE" == foreign ]]; then
      svc backhaul; svc backhaul-wss; svc backhaul-tcp; svc backhaul-health
      command -v tunnel-diagnose >/dev/null && tunnel-diagnose || true
    fi
    ;;
  test|diagnose)
    exec tunnel-diagnose
    ;;
  deep)
    exec tunnel-diagnose --deep
    ;;
  repair)
    exec tunnel-diagnose --repair
    ;;
  restart)
    if [[ "$ROLE" == iran ]]; then
      systemctl restart backhaul backhaul-wss backhaul-tcp haproxy
    elif [[ "$ROLE" == foreign ]]; then
      systemctl restart backhaul backhaul-wss backhaul-tcp backhaul-health
    fi
    sleep 3
    exec "$0" status
    ;;
  logs)
    if [[ "$ROLE" == iran ]]; then
      exec journalctl -u backhaul -u backhaul-wss -u backhaul-tcp -u haproxy -n 160 --no-pager
    else
      exec journalctl -u backhaul -u backhaul-wss -u backhaul-tcp -u backhaul-health -n 160 --no-pager
    fi
    ;;
  replace-foreign)
    [[ "$ROLE" == iran ]] || { echo 'replace-foreign must run on Iran.' >&2; exit 2; }
    new="${2:-}"; valid_ipv4 "$new" || { echo 'Usage: tunnelctl replace-foreign NEW_IP' >&2; exit 2; }
    old="$(bundle_get FOREIGN_IP)"
    if command -v ufw >/dev/null 2>&1; then
      [[ -n "$old" ]] && { ufw delete allow from "$old" to any port 3080 proto tcp >/dev/null 2>&1 || true; ufw delete allow from "$old" to any port 3081 proto tcp >/dev/null 2>&1 || true; }
      ufw allow from "$new" to any port 3080 proto tcp comment 'Backhaul TCPMux control' >/dev/null
      ufw allow from "$new" to any port 3081 proto tcp comment 'Backhaul plain TCP control' >/dev/null
    fi
    bundle_set FOREIGN_IP "$new"
    echo "Foreign IP updated: ${old:-unknown} -> $new"
    ;;
  replace-iran)
    [[ "$ROLE" == foreign ]] || { echo 'replace-iran must run on Foreign.' >&2; exit 2; }
    new="${2:-}"; valid_ipv4 "$new" || { echo 'Usage: tunnelctl replace-iran NEW_IP' >&2; exit 2; }
    old="$(bundle_get IRAN_IP)"
    sed -i -E "s|^remote_addr = \"[0-9.]+:3080\"$|remote_addr = \"$new:3080\"|" /etc/backhaul/client.toml
    sed -i -E "s|^remote_addr = \"[0-9.]+:3081\"$|remote_addr = \"$new:3081\"|" /etc/backhaul/client-tcp.toml
    bundle_set IRAN_IP "$new"
    systemctl restart backhaul backhaul-tcp backhaul-wss
    echo "Iran IP updated: ${old:-unknown} -> $new. Update backbone DNS to the new Iran IP."
    ;;
  *)
    echo 'Usage: tunnelctl {status|diagnose|deep|repair|restart|logs|replace-foreign NEW_IP|replace-iran NEW_IP}' >&2
    exit 2
    ;;
esac
