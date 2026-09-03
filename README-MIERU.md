# Mieru TCP Anti-DPI tunnel (Iran -> Foreign)

Pinned release: Mieru/Mita 3.36.0

Topology:
VPN users -> Xray/3x-ui on Iran -> SOCKS5 127.0.0.1:10808 -> Mieru TCP -> Mita foreign -> Internet

Default anti-DPI profile:
- TCP transport
- Multiple remote ports: 20000-20007
- Low Entropy: 48-bit mode (about 1.34x application-body expansion)
- Client TCP fragmentation: enabled, maxSleepMs=3
- Server TCP fragmentation: disabled for lower downstream latency
- Printable nonce prefix
- Random padding upper limits: 48 middle / 96 end
- Conservative multiplexing: LOW
- Standard handshake
- BBR
- NTP/Chrony
- 3-strike client watchdog

## 1) Foreign server

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/mieru-tunnel/install-foreign.sh -o install-foreign.sh
chmod +x install-foreign.sh
sudo ./install-foreign.sh
```

Save the printed username/password and make sure TCP 20000-20007 is allowed in the provider firewall/security group.

## 2) Iran server

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/mieru-tunnel/install-iran.sh -o install-iran.sh
chmod +x install-iran.sh
sudo ./install-iran.sh FOREIGN_IP USERNAME PASSWORD
```

If arguments are omitted, the script asks interactively.

## 3) Xray / 3x-ui outbound on Iran

Use SOCKS5 127.0.0.1:10808.

Minimal Xray outbound:

```json
{
  "tag": "mieru-out",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": 10808
      }
    ]
  }
}
```

## Health/debug

Foreign:
```bash
mita status
mita get connections
mita get users
mita describe effective-traffic-pattern
journalctl -u mita -n 100 --no-pager
ss -lntp | grep -E '2000[0-7]'
```

Iran:
```bash
systemctl status mieru-client --no-pager
mieru get connections
mieru get metrics
mieru describe effective-traffic-pattern
curl --socks5-hostname 127.0.0.1:10808 https://icanhazip.com
journalctl -u mieru-client -n 100 --no-pager
systemctl list-timers | grep mieru
```
