# Maya Failover Controller

Controller for the user's own Maya1/Maya3 infrastructure. It monitors the active Iran endpoint with a full VLESS+Reality end-to-end probe and switches the existing Cloudflare DNS A record only after repeated active-path failures and a verified healthy alternate path.

Initial deployment target: management server 88.216.70.225.

## Current production mapping

- MAYA1 main Iran: `185.215.230.204`
- MAYA1 spare Iran: `5.10.248.50`
- MAYA1 spare FRP control domain: `frp2.biya2film.top`
- MAYA3 main Iran: `94.184.4.38`
- MAYA3 spare Iran: `185.215.230.207`
- MAYA3 spare FRP control domain: `frp3.biya2film.top`

The active VLESS failover decision is based on the Iran endpoint IP and full user-path health. The FRP control domains are stored as topology metadata; they are not used as a weaker substitute for the end-to-end VLESS health check.

To apply these mappings safely to an existing management-server deployment, run `apply-current-mappings.sh`. The updater backs up the current config/state, stops only `maya-failover`, applies the mappings, runs diagnostics, and rolls back automatically if validation fails.
