# Lab Test Plan

Run only on test VPS pairs first.

## Success criteria
- Stable IKE/CHILD_SA establishment
- No stale XFRM policy after carrier restart
- Sustained bidirectional iperf3 throughput
- 30+ minutes continuous video playback without carrier-triggered freeze
- Packet loss and jitter recorded during path changes
- Native DFR mode remains available as fallback

## Failure criteria
- Frequent IKE reauth/rekey loops
- XFRM outer address resolves to loopback or carrier-local addresses
- MTU black-holing
- QUIC session recovery resets the inner SA
- Throughput collapse under concurrent streams
