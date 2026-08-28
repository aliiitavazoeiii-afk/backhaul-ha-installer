# Dragon Shield

Dragon Shield is a transport sidecar for **Dragon Fruit Relay (DFR)**. It leaves DFR's strongSwan/IKEv2, Linux XFRM, management, recovery and accounting logic intact, but carries the DFR endpoint traffic through a separate standards-based outer transport.

## Why this architecture

DFR itself is a route-based IKEv2/IPsec platform. Dragon Shield creates a small private overlay between each Ingress host and the Egress host. DFR then uses the Egress overlay IP as its endpoint.

```text
Xray / 3x-ui
     |
     v
DFR Ingress (strongSwan / XFRM)
     |
     |  private IPv4 endpoint
     v
Dragon Shield TUN
     |
     +-- primary: HTTP/3 WebTransport DATAGRAM over QUIC/TLS 1.3 / UDP 443
     |
     `-- fallback: HTTPS WebSocket / TCP 443
     |
     v
Dragon Shield TUN
     |
     v
DFR Egress (strongSwan / XFRM)
```

The public network does not directly carry DFR's IKEv2 packets when DFR is configured to use the Shield overlay address.

## Security model

- Standard TLS certificate verification; no `InsecureSkipVerify` mode.
- HTTP/3 WebTransport is the primary carrier and keeps packet semantics datagram-oriented, avoiding TCP head-of-line blocking in the normal path.
- WSS exists only as a compatibility fallback for networks where UDP/QUIC is unavailable.
- HMAC-SHA256 connection authentication with timestamp and cryptographic nonce.
- Replay cache rejects reused authentication nonces.
- Random authentication padding is sent inside TLS.
- Secret, randomized WebTransport and WebSocket paths.
- Invalid or unauthenticated requests receive an ordinary HTTP 404.
- QUIC 0-RTT is not enabled.
- Server enforces each Shield client's assigned overlay source IP and only permits packets between the assigned client IP and the server overlay IP. Dragon Shield is not a general-purpose routed VPN.
- Bounded packet queues drop under overload instead of allowing unbounded latency growth.

This design is intended to reduce exposed protocol fingerprinting. It is **not a guarantee of being undetectable or unblockable by every DPI system**.

## Packet sizing

The default Shield TUN MTU is **1080 bytes**. This deliberately keeps each WebTransport datagram below conservative QUIC path-MTU limits. Larger DFR/IPsec packets are fragmented only inside the private overlay and are never exposed as IP fragments on the public path.

This is a conservative production default. Once measured on the actual carriers, it can be increased if the path supports larger QUIC datagrams without loss.

## Install: Foreign / Egress

Create a DNS A record such as `shield.example.com` pointing to the foreign server, then run on Debian/Ubuntu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dragon-shield-v1/dragon-shield/install.sh) server \
  --domain shield.example.com \
  --client-id iran1 \
  --client-ip 10.203.0.2
```

The installer obtains a Let's Encrypt certificate (unless `--cert` and `--key` are supplied), builds Dragon Shield, configures the TUN interface, installs systemd, opens TCP/UDP 443 when UFW is active, and prints an enrollment token.

## Install: Iran / Ingress

Run the exact enrollment command printed by the Egress installer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dragon-shield-v1/dragon-shield/install.sh) client --enroll '...'
```

Then verify:

```bash
ping -c 3 10.203.0.1
systemctl status dragon-shield --no-pager
journalctl -u dragon-shield -f
```

A normal log line should show either:

```text
dragon-shield: connected to shield.example.com:443 via webtransport
```

or, if UDP/QUIC is not available:

```text
dragon-shield: connected to shield.example.com:443 via websocket
```

## Put DFR on top

Install upstream Dragon Fruit Relay normally on the foreign host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

Choose **Egress Hub**. When DFR asks for the Egress endpoint, use the Shield server address:

```text
10.203.0.1
```

Create the DFR connection and copy its DFR1 enrollment token. On the Iran host, run the same upstream installer, choose **Ingress Client**, and paste the DFR1 token.

The intended path is now:

```text
DFR IKEv2 -> 10.203.0.1 -> Dragon Shield -> HTTP/3 WebTransport -> foreign -> DFR
```

If a specific DFR release rejects an RFC1918 endpoint during enrollment, do not bypass its validation blindly. Use the compatibility procedure documented for that release or keep the deployment in test mode until the DFR endpoint contract is adapted.

## Add another Iran server

On the Egress server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dragon-shield-v1/dragon-shield/install.sh) add-client \
  --id iran2 \
  --ip 10.203.0.3
```

Copy the enrollment command it prints to the second Iran server. One UDP/TCP 443 listener can serve multiple authenticated Shield clients.

## Operations

```bash
# status
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dragon-shield-v1/dragon-shield/install.sh) status

# live logs
journalctl -u dragon-shield -f

# restart
systemctl restart dragon-shield

# remove Shield (does not delete Let's Encrypt certificates)
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dragon-shield-v1/dragon-shield/install.sh) uninstall
```

## Production validation before migration

Do not move all users immediately. First run one Ingress/Egress pair and measure for at least a full busy period:

- WebTransport vs fallback selection on each ISP.
- RTT, loss and reconnect count.
- YouTube/Instagram video continuity.
- CPU usage on both sides.
- Actual throughput with several simultaneous users.
- `journalctl` for carrier reconnects and queue drops.

The target condition is that normal traffic remains on WebTransport with zero or near-zero queue drops. Only after that should DFR users be migrated in batches.

## Upstream relationship

Dragon Shield is a separate transport component and does not copy or replace DFR's source code. Dragon Fruit Relay remains independently licensed under GPL-3.0-or-later by its upstream project.
