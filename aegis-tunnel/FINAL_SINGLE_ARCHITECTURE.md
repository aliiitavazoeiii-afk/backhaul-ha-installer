# Aegis Single Primary + Direct Fallback

Target deployment:

- Iran gateway: `94.184.4.38`
- Primary Foreign: `193.57.9.25`
- Primary data path: AegisMux over WSS
- Optional later fallback Foreign: direct TCP, no tunnel
- Public user entry remains the Iran gateway

This is **not active/active**. There is no round-robin user balancing.

```text
Users
  |
  v
Iran :443
  |
  +-- PRIMARY --> local Aegis data listener --> AegisMux/WSS --> Foreign-1 Xray 127.0.0.1:443
  |
  `-- BACKUP  --> Foreign-2 public :443   (only when primary health is DOWN)
```

The gateway uses a primary/backup backend. The backup does not receive normal traffic.

Primary health must represent the complete chain, not merely a local listening socket:

```text
Iran Aegis server
  -> authenticated carrier exists
  -> Foreign Aegis client is alive
  -> Foreign Xray 127.0.0.1:443 is TCP-reachable
```

When primary health fails, the gateway marks it DOWN and closes sessions using that path so clients reconnect to the backup. Existing TCP sessions cannot migrate byte-for-byte to another server; a client reconnect is unavoidable. New/reconnected sessions use the backup without a DNS change.

When primary recovers, it must pass multiple health checks before being marked UP. Existing backup sessions are not forcibly moved back; new sessions return to primary.

## Fallback requirements

The fallback Foreign must have the exact same user-facing Xray inbound identity as the primary (client UUIDs and protocol/security parameters). If the user-facing inbound uses keys, certificates, Reality keys, or other server identity material, the compatible values must exist on the fallback too.

Because the fallback is reached directly from Iran, its Xray listener must be reachable from `94.184.4.38` on the configured public port (normally TCP/443). It does not need Aegis.

## DNS

The normal user DNS record should continue pointing to the Iran gateway. A separate transport-only hostname is recommended for the Aegis WSS carrier. The Foreign Aegis client should pin `edge_ip=94.184.4.38`, so carrier connectivity does not depend on a DNS A-record lookup after installation.

Manual DNS movement to a Foreign remains a separate disaster-recovery option if the Iran gateway itself is lost.
