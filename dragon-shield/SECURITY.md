# Security notes

Dragon Shield uses public, standard cryptographic primitives provided by Go TLS, QUIC and WebTransport. It does not define a new encryption algorithm.

Connection authentication uses HMAC-SHA256 over client ID, timestamp, nonce and the configured secret path. Authentication values are transmitted only inside TLS. The server rejects stale timestamps and replayed nonces.

The transport is designed as a restricted point-to-point carrier for DFR. The server verifies source and destination overlay addresses before injecting packets into its TUN interface, preventing an authenticated client from using the service as a general L3 router.

Secrets are stored in `/etc/dragon-shield/*.json` with mode 0600. Do not paste enrollment tokens into public issue trackers, shell history shared with other users, or monitoring systems.

No claim is made that any traffic pattern is permanently indistinguishable from ordinary web traffic or immune to future DPI classification.
