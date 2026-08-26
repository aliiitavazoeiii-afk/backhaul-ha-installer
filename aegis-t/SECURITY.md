# Security notes

- Carrier authentication uses HMAC-SHA256 and constant-time signature comparison.
- Each carrier uses a cryptographically random nonce and path suffix.
- The server keeps a short replay cache and rejects duplicate nonces.
- The shared token is never sent directly in HTTP headers.
- TLS certificate verification is enabled on the Foreign client; there is no insecure-skip-verify mode.
- The installer uses strict SSH host-key handling and does not globally disable host verification.
- Aegis-T does not install, edit, export, import, or synchronize 3x-ui/Xray data.
- Unknown TLS/HTTP probes get a generic HTTP response rather than an Aegis-specific banner.

Traffic camouflage is defense-in-depth, not a guarantee of unobservability. Endpoint IP reputation, connection direction, timing, traffic volume, and network policy can still be used for classification or blocking.
