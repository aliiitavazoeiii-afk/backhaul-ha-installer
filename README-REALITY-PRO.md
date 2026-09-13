# Reality Pro

Reality Pro is the isolated VLESS + REALITY + XTLS Vision RAW branch for two-Foreign sticky routing and resilient failover.

It deliberately uses its own namespace and ports so it does not collide with the older `xhttp-dual` command set:

- CLI: `reality-pro`
- Iran services: `reality-pro-fabric.service`, `reality-pro-controller.service`
- Foreign service: `reality-pro-server.service`
- Iran config/state: `/etc/reality-pro`, `/var/lib/reality-pro`, `/opt/reality-pro`
- Foreign config/state: `/etc/reality-pro-server`, `/var/lib/reality-pro-server`, `/usr/local/lib/reality-pro`
- Stable home SOCKS: `127.0.0.1:12918`, `127.0.0.1:12919`
- Direct per-node probe SOCKS: `127.0.0.1:13018`, `127.0.0.1:13019`
- Local-only Routing API: `127.0.0.1:10085`

Do not run Reality Pro and xhttp-dual as simultaneous routing managers of the same x-ui database. The Iran installer refuses that configuration.

## Resilience design

- VLESS + REALITY + `xtls-rprx-vision` + RAW.
- Per-Foreign fresh UUID, X25519 credentials and short ID.
- Role-diverse target candidate order; F1 and F2 do not intentionally default to the same target.
- Per-node fingerprint and `spiderX` diversity.
- Randomized, high-threshold REALITY fallback bandwidth guards.
- Foreign outbound abuse guards: SMTP/25 and private/reserved destination ranges are blackholed.
- Sparse randomized external health probes: healthy nodes 75–180 seconds, unhealthy nodes 15–35 seconds.
- Multiple health endpoints with randomized order.
- Three failed probe cycles before failover, three successful cycles before recovery.
- Sticky users keep a stable `home=f1|f2` mapping.
- Node failover is performed inside a dedicated Xray fabric through RoutingService balancer override, so a health failover does **not** restart x-ui.
- When a recovered preferred node becomes healthy again, the corresponding home route is restored through the fabric without restarting x-ui.
- x-ui is only rewritten/restarted when the sticky user map itself changes (new/deleted users, manual rebalance, first install).

The same-ASN/provider correlation risk is **not solved** by this branch; it remains if both Foreign IPs come from the same network. Reality Pro improves the protocol/failover/abuse/health architecture around that constraint.

## Install Foreign F1

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/reality-pro/install-foreign-reality-pro.sh -o /root/install-foreign-reality-pro.sh
chmod +x /root/install-foreign-reality-pro.sh
/root/install-foreign-reality-pro.sh f1
cat /root/reality-pro-client.env
```

## Install Foreign F2

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/reality-pro/install-foreign-reality-pro.sh -o /root/install-foreign-reality-pro.sh
chmod +x /root/install-foreign-reality-pro.sh
/root/install-foreign-reality-pro.sh f2
cat /root/reality-pro-client.env
```

Copy each Foreign's values separately: IP, PORT, VLESS_ID, REALITY_PASSWORD, REALITY_SHORT_ID, SNI, FINGERPRINT and SPIDER_X.

## Install Iran

Requires an existing x-ui/3x-ui installation and VLESS users.

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/reality-pro/install-iran-reality-pro.sh -o /root/install-iran-reality-pro.sh
chmod +x /root/install-iran-reality-pro.sh
/root/install-iran-reality-pro.sh
```

The installer tests both Foreign paths end-to-end before touching x-ui routing.

## Operations

```bash
reality-pro status
reality-pro diagnose
reality-pro netcheck
```

Drain a node without changing the x-ui user map:

```bash
reality-pro drain f1
reality-pro undrain f1
```

or:

```bash
reality-pro drain f2
reality-pro undrain f2
```

A drain/failover changes the fabric balancer override live; it does not intentionally restart x-ui.

Manual 50/50 home rebalance (this changes the x-ui user map and therefore restarts x-ui once):

```bash
reality-pro rebalance --yes
```

## Uninstall Iran Reality Pro

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/reality-pro/uninstall-reality-pro.sh -o /root/uninstall-reality-pro.sh
chmod +x /root/uninstall-reality-pro.sh
/root/uninstall-reality-pro.sh
```

The uninstaller removes only Reality Pro managed x-ui rules/outbounds and preserves Reality Pro state/backups under `/var/lib/reality-pro`.

## Notes

- The health controller does not treat one transient failed request as a node failure.
- External probes are intentionally much less frequent than the old xhttp-dual v4 probes.
- Fake TCP/80 or UDP/443 decoy listeners are intentionally not added; a badly matched extra surface can increase rather than reduce fingerprinting risk.
- Fallback throttling is randomized per Foreign install because identical one-click fallback limits across a fleet would create another shared pattern.
