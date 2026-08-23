# Backhaul Project History / Canonical Continuity Notes

This file is the canonical non-secret project history for future work on this repository. It exists so later sessions can resume from validated architecture, known-good fixes, and prior failure analysis without re-discovering the same issues.

> Security rule: never commit secret bundles, tokens, UUID lists, private keys, panel credentials, or raw production secrets here.

## Project index

### 1. Custom Backhaul v2 (single-Foreign HA / Stealth-oriented transport)

Purpose: hardened single-Iran / single-Foreign tunnel with transport diversity and a custom WSSMux profile designed to reduce easy static signatures and active-probe oracles.

Historical experimental branch: `agent/custom-backhaul-v2`.

Known historical refs from the validated development cycle:

- v2 experimental branch head observed around `4591ba09b9c359c277a4e81b75f3c6cf6f504e6c`
- deployment wrapper observed at `8d26bef39d9870294433c280eb01eac07b290d2b`
- custom payload ref observed at `9aaa19300b1a76389695570b0652a2dae19b8743`
- open PR historically known as PR #1: `Validated custom Backhaul v2 HA transport stack`
- PR #1 must not be merged without explicit operator authorization.

#### v2 intended architecture

```text
Iran public :443
      |
   HAProxy
  SNI routing
 /          \
bh1...       edge1...
  |             |
stunnel :9443   stunnel :9444
  |             |
nginx HTTP      raw TCPMux
:9080           :18081
  |
Backhaul WSMux :18080
```

User-path preference:

1. custom WSSMux primary through public 443 / HAProxy SNI / stunnel / nginx decoy + secret path / Backhaul WSMux
2. TLS-wrapped TCPMux backup on separate SNI
3. IP-restricted plain TCP emergency backup

#### v2 intended HAProxy user backend

```haproxy
backend vpn_users
    mode tcp
    option redispatch
    retries 2
    option httpchk
    http-check send meth GET uri /healthz ver HTTP/1.1 hdr Host localhost
    http-check expect status 200
    server wss_primary 127.0.0.1:10443 check port 10444 inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
    server tcp_backup 127.0.0.1:11443 check port 11444 inter 2s fall 2 rise 2 backup
    server tcp_plain_backup 127.0.0.1:12443 check port 12444 inter 2s fall 2 rise 2 backup
```

#### v2 intended SNI routing

```haproxy
tcp-request inspect-delay 5s
tcp-request content accept if { req.ssl_hello_type 1 }

acl is_backbone req.ssl_sni -i bh1.biya2film.top
acl is_tcptls req.ssl_sni -i edge1.biya2film.top

use_backend backhaul_tcptls if is_tcptls
use_backend backhaul_wss if is_backbone
default_backend vpn_users

backend backhaul_tcptls
    mode tcp
    server tcptls_control 127.0.0.1:9444

backend backhaul_wss
    mode tcp
    server wss_control 127.0.0.1:9443
```

#### Custom Backhaul v2 provenance and behavior

The custom binary was derived from Musixal/Backhaul v0.7.2. Historical upstream commit used during development: `df7966f8f725837a680ea7b90bd37ea52666c277`.

Stock v0.7.2 SHA256 used as the pinned reference build:

`7f1b1439d7fe1d15ae0b376e15614fe13d8a12f6e07a90263e310ea2a9d601fb`

Custom v2 changes included:

- WSS certificate verification by default
- `tls_skip_verify=true` compatibility mode
- uTLS Chrome-like ClientHello
- ALPN `http/1.1`
- per-deployment `ws_control_path` and `ws_tunnel_path`
- generic 404 response for unauthorized probing
- padded WSMux control frames while preserving byte 0
- bounded heartbeat jitter
- configurable User-Agent / Origin
- preferred public path does not expose obvious raw control endpoints

Threat model: remove easy static signatures / obvious active-probe oracles; do **not** claim invisibility against state-level DPI or traffic analysis.

#### Important v2 failure discovered: nginx TLS termination caused one-way stalls

Symptom: TLS/WSS path could establish but traffic became one-way or stalled.

Root cause in the tested layout: nginx performing TLS termination in the same path produced problematic behavior.

Validated fix:

```text
TLS -> stunnel -> nginx HTTP -> Backhaul
```

Separating TLS termination into stunnel and leaving nginx as HTTP routing fixed the one-way stall in lab testing.

#### v2 validation history

Historical final lab results:

- Phase 2: 23 OK / 0 WARN / 0 FAIL
- Phase 3: 16 OK / 0 WARN / 0 FAIL
- health endpoints 200
- decoy 200
- unknown path 404
- unauthorized secret-path access 404
- failover/failback validated across WSS -> TLS TCPMux -> plain -> TLS TCPMux -> WSS
- reboot on both hosts passed
- real VPN user traffic worked

Historical throughput samples:

- WSS Iran->Foreign: ~228 / 226 / 231 Mbps
- TLS TCPMux Iran->Foreign: ~308 Mbps
- TLS TCPMux reverse: ~234 Mbps
- plain TCP: ~392 Mbps / ~256 Mbps

### 2. Maya1 outage analysis (important troubleshooting lesson)

Production pair involved during investigation:

- Iran Maya1: `5.10.248.50`
- one Foreign used in the incident: `46.8.228.117`
- WSS domain used in that investigation: `bh3.biya2film.top`

Observed recurring pattern: worked for hours, then latency/slowdown, then all tunnel transports became unusable while ICMP remained healthy.

Tunnel-level symptoms included all three end-to-end health paths timing out while services/listeners remained up.

Foreign logs showed:

- WSS abnormal closure `1006 unexpected EOF`
- TCPMux control read timeouts
- local health endpoint itself still returned 200
- Python health server sometimes logged `BrokenPipe` because the tunneled caller timed out/closed before the response completed
- ESTABLISHED sockets could coexist with non-zero Send-Q / FIN-WAIT states

#### Decisive isolation test: raw iperf outside Backhaul

A raw iperf3 server was opened directly on the Iran host, completely outside Backhaul/HAProxy/health mappings.

Result from the Foreign host:

- TCP handshake succeeded
- transfer remained `0.00 Bytes / 0.00 bits/sec`
- retransmissions occurred
- iperf eventually failed to receive results

Conclusion: the current outage could not be attributed solely to Backhaul, WSS, TCPMux, HAProxy, or the shared health endpoint. Raw TCP payload itself was stalling after handshake.

Important diagnostic model:

```text
SYN      -> reaches
SYN/ACK  <- reaches
ESTABLISHED
DATA     -> stalls / blackholes
```

Likely failure domain moved below the tunnel software: provider/upstream policy, stateful filtering, anti-DDoS/policer, route-specific asymmetric blackholing, or host/network TCP pathology.

Do **not** claim national DPI as proven without packet-level evidence.

Useful packet-level commands for future recurrence:

Iran side:

```bash
tcpdump -ni any -nn -tttt 'host <FOREIGN_IP> and tcp port 5202' -c 100
```

Foreign side:

```bash
tcpdump -ni any -nn -tttt 'host <IRAN_IP> and tcp port 5202' -c 100
```

Useful socket-state inspection:

```bash
ss -tin dst <IRAN_IP>
ss -tin src <FOREIGN_IP>
```

Lesson: preserve the failure state. Do not reboot/reinstall before running raw-path A/B tests, otherwise evidence is destroyed.

### 3. Dual-Foreign Active/Active project

Branch: `agent/dual-foreign-active-active`

Purpose: one Iran ingress with two simultaneous Foreign exits, splitting user connections so one Foreign IP does not carry the full sustained traffic/connection profile.

Current production-test topology:

- Iran: `5.10.248.50`
- Foreign A: `193.57.9.144`
- Foreign B: `193.57.9.192`
- Domain A: `bh3.biya2film.top`
- Domain B: `bh3b.biya2film.top`

This project is deliberately isolated from custom Backhaul v2. The current Dual-Foreign implementation uses **stock Backhaul v0.7.2 WSSMux as primary**, not the custom v2 Stealth WSS transport.

Current transport order inside each Foreign slot:

```text
WSSMux -> TCPMux -> plain TCP
```

#### Dual-Foreign architecture

```text
                    Iran :443 / HAProxy
                           |
                 sticky Active/Active
                    /              \
                   /                \
         Foreign A slot         Foreign B slot
          WSS/MUX/TCP            WSS/MUX/TCP
               |                      |
        Xray 127.0.0.1:443     Xray 127.0.0.1:443
```

Each Foreign slot has independent transport tokens, control connections, health, and Backhaul processes.

Port plan:

| Function | A | B |
|---|---:|---:|
| WSS control loopback Iran | 8443 | 8543 |
| TCPMux control Iran | 3080 | 3180 |
| plain TCP control Iran | 3081 | 3181 |
| WSS user data | 10443 | 20443 |
| WSS health | 10444 | 20444 |
| TCPMux user data | 11443 | 21443 |
| TCPMux health | 11444 | 21444 |
| plain user data | 12443 | 22443 |
| plain health | 12444 | 22444 |
| slot frontend | 15001 | 15002 |
| aggregate slot health | 15011 | 15012 |

#### Dual project installation isolation

The Dual project intentionally uses separate names/paths from v2 where possible:

- binary: `/usr/local/bin/backhaul-dual`
- configs: `/etc/dual-backhaul`
- state: `/etc/dual-backhaul-ha`
- services: `dual-bh-*`

On the same Iran host, v2 and Dual cannot both own public `:443` simultaneously. Switching projects requires only one public-ingress stack to be active at a time.

#### Dual project initial load-balancing result

Initial `leastconn` test distributed active HAProxy connections essentially 50/50, e.g. observed `68/68` and later `34/34`.

Problem discovered: per-connection leastconn caused a single user's traffic to exit through A and B at the same time, so the user's visible public IP could change repeatedly without disconnecting.

This is undesirable for services such as Instagram and other anti-abuse/session-sensitive systems.

#### Sticky-user fix

Added project patch:

`dual-foreign-active-active/enable-sticky-users.sh`

Behavior:

- top-level assignment becomes round-robin for new source IPs
- source IP is persisted with a HAProxy stick-table
- same source stays on the same Foreign for normal reconnects/parallel connections
- stick lifetime is 24h of activity
- if a slot becomes unavailable, reconnects may be redistributed to the surviving slot

Core HAProxy model:

```haproxy
backend vpn_users
    mode tcp
    balance roundrobin
    stick-table type ip size 1m expire 24h
    stick on src
    option redispatch
    retries 2
```

Caveat: stickiness is by **source public IP**, not Xray UUID. Multiple users behind the same CGNAT public IP can be assigned to the same Foreign.

Also, a live TCP connection cannot be migrated losslessly between Foreign servers after a sudden server death. Existing sessions on the dead Foreign die; the client must reconnect. The target is fast reconnect/failover, not impossible zero-interruption TCP migration.

#### Important Dual failure discovered: health did not include Xray readiness

Original health only verified that Backhaul could reach the Foreign-local health service. If Xray/inbound itself was disabled, tunnel health could remain 200 and HAProxy would keep routing users into a dead application endpoint.

Added project patch:

`dual-foreign-active-active/enable-xray-aware-health.sh`

New requirement: Foreign health returns healthy only when local Xray `127.0.0.1:443` is actually accepting connections.

#### Fast failover patch

Added project patch:

`dual-foreign-active-active/enable-fast-failover.sh`

Goal: detect a failed Foreign/application path much faster and close sessions associated with the down slot so clients reconnect through the surviving slot.

Historical target timing used in the patching cycle:

- `inter 1s`
- `fall 1`
- `rise 2`
- `on-marked-down shutdown-sessions`

#### Validated current Dual state

Iran `dual-diagnose` reached all-OK status for:

- all six Backhaul transport services
- HAProxy
- A WSS / MUX / TCP health
- A aggregate slot
- B WSS / MUX / TCP health
- B aggregate slot

Foreign diagnostics reached all-OK after Xray was installed and listening on `127.0.0.1:443`.

Active/Active distribution was validated.

Sticky behavior was introduced after discovering visible-IP churn.

Xray-aware health + fast failover were then tested, and a Foreign/Xray outage successfully failed users over on reconnect to the surviving Foreign.

### 4. User management requirement for Dual-Foreign

Because HAProxy chooses a Foreign before Xray user authentication, both Foreign Xray instances must recognize the same user/UUID definitions.

Do not copy the entire `x-ui.db` blindly between active servers. That copies unrelated panel/server state and tightly couples the two nodes.

Planned control-plane design:

```text
Operator adds/updates/deletes user once
              |
              v
Foreign A (management source)
              |
          user-sync
              |
              v
Foreign B
```

Rules:

- data-plane availability must not depend on the sync controller
- sync should use an API/management layer where possible
- operations must be idempotent
- first safe mode should be additive/update-only
- destructive delete mirroring must require explicit enablement
- sync failure should alert but must never stop the tunnel
- credentials remain in root-only local secret files, never Git

### 5. Operational rules learned across both projects

1. Never paste secret bundle contents into chat or GitHub.
2. Never merge the historical v2 PR without explicit operator approval.
3. Do not reinstall/reboot during an active failure until raw-path evidence is captured.
4. Separate health layers: tunnel health and application/Xray health are not the same thing.
5. An ESTABLISHED TCP socket does not prove payload flow is healthy.
6. If all transports fail simultaneously, test raw TCP outside the tunnel before rewriting the protocol stack.
7. Heavy diagnostics such as multi-iperf deep tests can consume significant bandwidth; use them deliberately.
8. Prefer lightweight `dual-diagnose` / normal tunnel diagnostics in production.
9. Keep v2 and Dual-Foreign installers/services isolated so either architecture can be used later without destroying the other project's configuration/history.
10. When a change fixes a production issue, record both the symptom and the reason for the fix here—not only the final command.

## Continuity procedure for future work

At the beginning of future Backhaul work, inspect this file plus the relevant project README/installer before changing production.

For single-Foreign Stealth/v2 work, use the v2 project/branch and its validated stunnel -> nginx HTTP architecture.

For two-Foreign Active/Active work, use `agent/dual-foreign-active-active` and preserve sticky-user + Xray-aware-health + fast-failover behavior.

When a new bug is found and validated, append:

- observed symptom
- root cause or current best-supported cause
- exact fix
- validation test
- whether the fix is project-specific or reusable across projects
