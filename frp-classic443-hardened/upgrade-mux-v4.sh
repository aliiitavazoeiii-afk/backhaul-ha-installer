#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"
ROLE=unknown
[[ -f /etc/frp-nomux/frps.toml ]] && ROLE=iran
[[ -f /etc/frp-nomux/frpc.toml ]] && ROLE=foreign
[[ "$ROLE" != unknown ]] || { echo '[x] Classic443 installation not detected.' >&2; exit 1; }

echo "[+] Detected role: $ROLE"

if [[ "$ROLE" == iran ]]; then
  F=/etc/frp-nomux/frps.toml
  cp -a "$F" "$F.pre-mux-v4-${TS}.bak"

  # Multiplex hundreds of logical work streams over a small number of carrier
  # TCP/WSS connections. A larger logical pool absorbs VPN fan-out bursts.
  sed -E -i 's/^transport\.tcpMux[[:space:]]*=.*/transport.tcpMux = true/' "$F"
  sed -E -i 's/^transport\.maxPoolCount[[:space:]]*=.*/transport.maxPoolCount = 256/' "$F"
  if grep -q '^transport\.tcpMuxKeepaliveInterval' "$F"; then
    sed -E -i 's/^transport\.tcpMuxKeepaliveInterval[[:space:]]*=.*/transport.tcpMuxKeepaliveInterval = 30/' "$F"
  else
    sed -i '/^transport\.tcpMux = true/a transport.tcpMuxKeepaliveInterval = 30' "$F"
  fi
  sed -E -i 's/^userConnTimeout[[:space:]]*=.*/userConnTimeout = 30/' "$F"

  /opt/frp-nomux/bin/frps verify -c "$F" >/dev/null || {
    cp -a "$F.pre-mux-v4-${TS}.bak" "$F"
    echo '[x] frps config validation failed; restored backup.' >&2
    exit 1
  }

  mkdir -p /etc/systemd/system/frps-nomux.service.d
  cat >/etc/systemd/system/frps-nomux.service.d/30-mux-v4.conf <<'EOF'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=6

[Service]
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=262144
EOF
  systemctl daemon-reload

  echo '[i] Restarting FRPS once to activate tcpMux=true. Existing tunnel sessions will drop during this migration.'
  systemctl restart frps-nomux
  sleep 3
  systemctl is-active --quiet frps-nomux || {
    tail -n 120 /var/log/frp-nomux/frps.log 2>/dev/null || true
    echo '[x] frps failed after mux migration.' >&2
    exit 1
  }

  echo '[+] IRAN mux-v4 active.'
  grep -E '^transport\.(tcpMux|maxPoolCount|tcpMuxKeepaliveInterval)|^userConnTimeout' "$F"
  systemctl show frps-nomux -p ActiveState -p MemoryCurrent -p MemoryPeak -p NRestarts

else
  F=/etc/frp-nomux/frpc.toml
  cp -a "$F" "$F.pre-mux-v4-${TS}.bak"

  sed -E -i 's/^transport\.tcpMux[[:space:]]*=.*/transport.tcpMux = true/' "$F"
  sed -E -i 's/^transport\.poolCount[[:space:]]*=.*/transport.poolCount = 128/' "$F"
  if grep -q '^transport\.tcpMuxKeepaliveInterval' "$F"; then
    sed -E -i 's/^transport\.tcpMuxKeepaliveInterval[[:space:]]*=.*/transport.tcpMuxKeepaliveInterval = 30/' "$F"
  else
    sed -i '/^transport\.tcpMux = true/a transport.tcpMuxKeepaliveInterval = 30' "$F"
  fi
  sed -E -i 's/^transport\.dialServerTimeout[[:space:]]*=.*/transport.dialServerTimeout = 12/' "$F"

  # No proxy-level health polling; it creates artificial user-plane churn.
  sed -i '/^healthCheck\.type = "tcp"$/,/^healthCheck\.intervalSeconds = /d' "$F"

  /opt/frp-nomux/bin/frpc verify -c "$F" >/dev/null || {
    cp -a "$F.pre-mux-v4-${TS}.bak" "$F"
    echo '[x] frpc config validation failed; restored backup.' >&2
    exit 1
  }

  mkdir -p /etc/systemd/system/frpc-nomux.service.d
  cat >/etc/systemd/system/frpc-nomux.service.d/30-mux-v4.conf <<'EOF'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=6

[Service]
# With mux enabled the legitimate stream count can be high, so keep a generous
# but finite circuit breaker. FRPC itself is still forbidden from swapping.
MemoryHigh=512M
MemoryMax=768M
MemorySwapMax=0
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=262144
Environment=GOMEMLIMIT=512MiB
Environment=GOGC=100
EOF
  systemctl daemon-reload

  echo '[i] Restarting FRPC once to activate tcpMux=true.'
  systemctl restart frpc-nomux
  sleep 5
  systemctl is-active --quiet frpc-nomux || {
    tail -n 120 /var/log/frp-nomux/frpc.log 2>/dev/null || true
    echo '[x] frpc failed after mux migration.' >&2
    exit 1
  }

  # Clear stale project swap only if there is enough free RAM. FRPC cannot use
  # swap after this migration due to MemorySwapMax=0.
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq '/swapfile-frp-resilience'; then
    avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    used_kb="$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk '$1=="/swapfile-frp-resilience" {print int($2/1024)}')"
    used_kb="${used_kb:-0}"
    if (( avail_kb > used_kb + 262144 )); then
      swapoff /swapfile-frp-resilience && swapon /swapfile-frp-resilience || true
    fi
  fi

  echo '[+] FOREIGN mux-v4 active.'
  grep -E '^transport\.(tcpMux|poolCount|tcpMuxKeepaliveInterval|dialServerTimeout)' "$F"
  systemctl show frpc-nomux -p ActiveState -p MainPID -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemoryMax -p NRestarts
  ps -C frpc -o pid,%cpu,%mem,rss,vsz,nlwp,etime,cmd || true
  source /root/frp-nomux.env 2>/dev/null || true
  if [[ -n "${IRAN_IP:-}" ]]; then
    echo -n 'Physical established TCP connections FRPC -> Iran:443: '
    ss -Htn state established dst "${IRAN_IP}:443" | wc -l
  fi
fi

echo '[+] mux-v4 migration complete.'
