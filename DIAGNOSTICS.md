# Tunnel diagnostics

The diagnostic module is designed for two common incidents:

1. VPN disconnected / unstable
2. VPN connects but speed is unusually low

It does not label a path as "filtered" from one failed probe. It reports the strongest supported diagnosis, for example `possible WSS/443 path filtering or WSS failure` when WSS fails while TCP remains reachable.

## One-time setup

Run this once on **Foreign first**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/enable-diagnostics.sh)
```

Then run the same command once on **Iran**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/enable-diagnostics.sh)
```

The Iran-side setup restarts the two Backhaul services once because it adds private diagnostic mappings.

### Diagnostic-only ports

- WSSMux: Iran `10445` -> Foreign `127.0.0.1:5201`
- TCPMux: Iran `11445` -> Foreign `127.0.0.1:5201`
- Foreign iperf3 listens only on `127.0.0.1:5201`

No public firewall rule is added for these ports.

## Fast diagnosis

On either server:

```bash
tunnel-diagnose
```

Checks include:

- Backhaul / WSSMux / HAProxy / health service status
- Xray listener on Foreign `127.0.0.1:443`
- WSS and TCP end-to-end health
- HAProxy recent WSS DOWN / TCP backup activity
- WSS TLS/SNI reachability from Foreign
- TCPMux control reachability from Foreign
- DNS and certificate status
- peer route, ping loss and latency
- interface MTU and discovered PMTU
- Don't-Fragment packet probes
- NIC errors/drops
- CPU load, available memory, disk and conntrack usage
- NTP sync
- a short TCP retransmission-rate sample

## Speed diagnosis

Run from **Iran**:

```bash
tunnel-diagnose --deep
```

In addition to all normal checks it measures four paths independently:

```text
WSS  Iran -> Foreign
WSS  Foreign -> Iran
TCP  Iran -> Foreign
TCP  Foreign -> Iran
```

This makes it possible to distinguish cases such as:

- WSS slow while TCP is fast -> likely WSS-specific/path issue
- TCP slow while WSS is fast -> likely TCPMux-specific issue
- both transports slow + loss/retransmission -> likely network route/path quality
- both transports healthy/fast but end-user VPN slow -> investigate Xray, user ISP/client path, or user-facing ingress next

## Exit codes

- `0`: no significant issue detected
- `1`: warning / degradation detected
- `2`: a failed critical check was detected

The final `Diagnosis` section is intended to be the first thing to use when troubleshooting.
