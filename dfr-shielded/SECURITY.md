# Security Model

The shield layer is transport/camouflage only. It must not replace the authenticated encryption, key exchange or anti-replay protections of standard IKEv2/IPsec.

Requirements:
- TLS 1.3 for the outer carrier
- certificate validation or explicit pinning
- per-connection authorization token bound to the TLS session
- no unauthenticated management endpoint
- bounded, randomized padding only after authentication
- replay-resistant session establishment
- rate limiting for invalid peers
- fail closed on authentication errors

No claim of being "DPI-proof" is made; resistance to classification must be measured on real networks.
