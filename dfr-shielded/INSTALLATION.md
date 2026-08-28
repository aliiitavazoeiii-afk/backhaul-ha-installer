# Installation (lab only)

1. Install Dragon Fruit Relay v2.1.0 normally on a test egress and ingress pair.
2. Keep native DFR connectivity working before enabling any shield layer.
3. Copy `config.example.env` to `/etc/dfr-shielded/config.env` and set test endpoints.
4. Install `systemd/dfr-shielded.service` only after the carrier binary exists.
5. Validate the gates in `TESTING.md` before any production use.

There is intentionally no production one-line installer yet because the XFRM endpoint semantics must first be validated end-to-end; shipping an installer before that would create a misleading partially-working tunnel.
