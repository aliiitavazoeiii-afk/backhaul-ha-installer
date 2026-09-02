#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"
changed=0

# IRAN: remove the 1-second TCP health-check on the FRP user proxy.
# With tcpMux=false each TCP check can consume/create a real FRP work connection,
# causing continuous churn even when there are no users.
if [[ -f /etc/haproxy/haproxy.cfg ]] && grep -q 'server frp_user 127\.0\.0\.1:10445' /etc/haproxy/haproxy.cfg; then
  cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.pre-frp-stability-${TS}.bak"
  sed -E -i 's#^([[:space:]]*server[[:space:]]+frp_user[[:space:]]+127\.0\.0\.1:10445)[[:space:]]+check([[:space:]].*)?$#\1#' /etc/haproxy/haproxy.cfg
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
  systemctl reload haproxy
  echo '[+] IRAN: removed HAProxy 1-second health-check from 127.0.0.1:10445; graceful reload done.'
  changed=1
fi

# FOREIGN: reduce pre-created WSS work connections. poolCount is a reserve, not
# a concurrency cap; FRP opens additional work connections on demand.
if [[ -f /etc/frp-nomux/frpc.toml && -x /opt/frp-nomux/bin/frpc ]]; then
  cp -a /etc/frp-nomux/frpc.toml "/etc/frp-nomux/frpc.toml.pre-stability-${TS}.bak"
  sed -E -i 's/^transport\.poolCount[[:space:]]*=.*/transport.poolCount = 6/' /etc/frp-nomux/frpc.toml

  if ! /opt/frp-nomux/bin/frpc verify -c /etc/frp-nomux/frpc.toml >/dev/null 2>&1; then
    cp -a "/etc/frp-nomux/frpc.toml.pre-stability-${TS}.bak" /etc/frp-nomux/frpc.toml
    echo '[x] FOREIGN: frpc config validation failed; restored backup.' >&2
    exit 1
  fi

  mkdir -p /etc/systemd/system/frpc-nomux.service.d
  cat >/etc/systemd/system/frpc-nomux.service.d/20-frp-stability.conf <<'EOF'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
# Normal frpc usage is far below these values. These are circuit breakers,
# not performance targets.
MemoryHigh=128M
MemoryMax=256M
MemorySwapMax=0
RestartSec=15s
EOF

  systemctl daemon-reload
  systemctl restart frpc-nomux
  sleep 4
  systemctl is-active --quiet frpc-nomux || {
    journalctl -u frpc-nomux -n 80 --no-pager
    echo '[x] FOREIGN: frpc-nomux did not come back up.' >&2
    exit 1
  }

  echo '[+] FOREIGN: poolCount=6; MemoryHigh=128M; MemoryMax=256M; MemorySwapMax=0; RestartSec=15s.'

  # Clear stale pages from the dedicated emergency swap only when it is safe.
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq '/swapfile-frp-resilience'; then
    avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_used_kb="$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk '$1=="/swapfile-frp-resilience" {print int($2/1024)}')"
    swap_used_kb="${swap_used_kb:-0}"
    if (( avail_kb > swap_used_kb + 262144 )); then
      swapoff /swapfile-frp-resilience
      swapon /swapfile-frp-resilience
      echo '[+] FOREIGN: stale FRP emergency swap pages cleared safely.'
    else
      echo '[i] FOREIGN: swap left as-is; not enough free RAM for a safe swapoff right now.'
    fi
  fi

  changed=1
fi

if (( changed == 0 )); then
  echo '[i] No Classic443 FRP components detected on this host.'
fi

echo
echo '=== POST-HOTFIX ==='
if systemctl list-unit-files frpc-nomux.service >/dev/null 2>&1; then
  systemctl show frpc-nomux \
    -p ActiveState -p MainPID -p MemoryCurrent -p MemoryPeak \
    -p MemorySwapCurrent -p MemorySwapPeak -p NRestarts
  ps -C frpc -o pid,%cpu,%mem,rss,vsz,etime,cmd || true
  echo 'WSS connections:'
  source /root/frp-nomux.env 2>/dev/null || true
  [[ -n "${IRAN_IP:-}" ]] && ss -Htn state established dst "${IRAN_IP}:443" | wc -l || true
fi
if [[ -f /etc/haproxy/haproxy.cfg ]] && grep -q 'server frp_user 127\.0\.0\.1:10445' /etc/haproxy/haproxy.cfg; then
  grep -n 'server frp_user' /etc/haproxy/haproxy.cfg
fi
