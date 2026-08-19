# Tunnel diagnostics

The diagnostic module is the operational troubleshooting layer for this project. Keep troubleshooting commands here so chat can focus on interpreting results and root-cause analysis.

## Install / update diagnostics

Run `enable-diagnostics.sh` once on Foreign first and then on Iran. Re-running it updates the diagnostic tool safely and is idempotent.

Foreign runs a private iperf3 server on `127.0.0.1:5201`. Iran adds two private Backhaul mappings:

- WSSMux: Iran `10445` -> Foreign `127.0.0.1:5201`
- TCPMux: Iran `11445` -> Foreign `127.0.0.1:5201`

No public firewall rule is added for these ports.

## Command reference

`tunnel-diagnose` — fast diagnosis for disconnects, instability, unexpected failover, or a quick health check.

`tunnel-diagnose --deep` — run on Iran when speed is low. It adds four throughput tests: WSS Iran->Foreign, WSS Foreign->Iran, TCP Iran->Foreign, and TCP Foreign->Iran.

`tunnel-diagnose --repair` — conservative local repair mode. It only restarts `backhaul-wss` when the collected evidence matches a WSSMux-stall pattern. It does not automatically restart Xray, HAProxy, TCPMux, or the whole server.

`tunnel-diagnose --deep --repair` — combine deep speed diagnosis with conservative repair.

## WSS stall detection

Foreign diagnosis no longer treats a successful TLS connection as proof that WSSMux is healthy. It also checks for recent WSS heartbeat and Backhaul health traffic. This detects the failure pattern where TLS/SNI works and the service is active, but the WSSMux session/data plane is stalled.

The safe Foreign repair pattern is:

- WSS TLS/SNI path reachable
- TCPMux control reachable
- TCP data-plane health traffic present
- WSS data-plane health traffic absent
- `backhaul-wss` service active

The safe Iran repair pattern is:

- WSS end-to-end health failed
- TCP end-to-end health healthy
- HAProxy valid
- local `backhaul-wss` active

If an Iran-side WSS restart does not restore end-to-end health, the diagnosis points to a likely Foreign WSS client stall rather than blindly restarting more services.

## What is checked

- Backhaul / WSSMux / HAProxy / health service status
- Xray listener on Foreign `127.0.0.1:443`
- WSS and TCP end-to-end health
- HAProxy recent WSS DOWN / TCP backup activity
- WSS TLS/SNI reachability from Foreign
- TCPMux control reachability from Foreign
- recent WSS heartbeat and data-plane health traffic on Foreign
- DNS and certificate status
- peer route, ping loss and latency
- interface MTU and PMTU
- Don't-Fragment packet probes
- CPU, memory and disk pressure
- TCP retransmission sample
- optional bidirectional WSS/TCP throughput

## Diagnosis principles

The tool does not claim "filtered" from a single failed probe. It separates layers:

- TLS/SNI failed while TCP works -> possible WSS/443 path, TLS/DNS, HAProxy, or WSS issue
- TLS/SNI works but recent WSS health traffic disappears while TCP stays healthy -> likely WSSMux session/data-plane stall
- WSS end-to-end fails while TCP end-to-end works -> HAProxy should fail over to TCP backup
- both WSS and TCP fail -> broader Foreign/Xray/path failure
- both transports healthy but speed is low with loss/retransmission/PMTU warnings -> path-quality issue
- WSS throughput far below TCP -> WSS-specific degradation
- TCP throughput far below WSS -> TCPMux-specific degradation

## Exit codes

- `0`: no significant issue detected
- `1`: warning / degradation detected
- `2`: failed critical check detected

Share the final `Diagnosis` section and `Summary` in troubleshooting chat; share the full output only when the diagnosis is ambiguous.