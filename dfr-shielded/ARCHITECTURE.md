# DFR Shielded Architecture

## Goal
Preserve Dragon Fruit Relay's registry, management, health/recovery, accounting and endpoint lifecycle while adding a replaceable carrier layer.

## Non-goals
- Do not invent new cryptography.
- Do not weaken IPsec authentication or anti-replay.
- Do not place all user traffic into one TCP stream.

## Carrier contract
A carrier implementation must provide:
- authenticated peer establishment
- replay-resistant session setup
- multiplexed datagram delivery
- bounded padding
- keepalive and path liveness
- endpoint migration
- MTU discovery / explicit MTU ceiling
- per-session statistics

## Initial implementation target
QUIC/TLS 1.3 datagram carrier, one logical carrier session per DFR connection, with IPsec remaining the inner security layer. This is intended as a lab implementation until DFR strongSwan/XFRM integration is validated end-to-end.

## Safety invariant
The carrier is obfuscation/transport only. Confidentiality, integrity and peer identity remain the responsibility of standard TLS 1.3 for the carrier and IPsec/IKEv2 for the inner tunnel.
