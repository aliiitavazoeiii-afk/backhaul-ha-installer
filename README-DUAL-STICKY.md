# XHTTP Dual Sticky Failover

Two independent XHTTP + REALITY foreign servers behind one Iran/x-ui server, with **sticky per-VLESS-user routing** and automatic failover.

## Behavior

- Every enabled VLESS client is identified by its Xray `email`.
- New users are assigned 50/50 (`f1`, `f2`) and the assignment is persisted in `/var/lib/xhttp-dual/state.json`.
- A user's traffic always uses the same foreign path while that path is healthy.
- Health checks run from the Iran server through each real tunnel to `https://cp.cloudflare.com/generate_204`.
- Default health interval: 15 seconds.
- Default failure threshold: 3 consecutive failures.
- Default recovery threshold: 5 consecutive successes.
- If one foreign fails, all users currently on it are moved to the healthy foreign.
- When the failed foreign recovers, users are **not** moved back automatically. This avoids egress-IP flips and route flapping.
- New users after recovery are assigned to the less-loaded healthy node.
- `xhttp-dual rebalance --yes` manually restores an even 50/50 split. This can change active users' public IPs.

## x-ui integration

The controller manages only two outbound tags and routing rules carrying the `xhttp-dual:` ruleTag prefix:

- `xhttp-dual-f1` -> SOCKS `127.0.0.1:11818`
- `xhttp-dual-f2` -> SOCKS `127.0.0.1:11819`

It reads enabled VLESS client emails from the local x-ui SQLite DB (`/etc/x-ui/x-ui.db`). Before every managed write it creates a SQLite backup under `/var/lib/xhttp-dual/backups`. If x-ui fails to restart after a change, the previous Xray template is restored automatically.

Existing x-ui routing/outbounds are preserved. Managed user rules are inserted before a generic catch-all rule, so existing private/direct rules that appear earlier remain effective.

## Foreign install

Run the normal final XHTTP foreign installer independently on **both** foreign VPSs:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover/install-foreign.sh -o /root/install-foreign.sh
chmod +x /root/install-foreign.sh
/root/install-foreign.sh
```

On each foreign server save the output of:

```bash
cat /root/xhttp-reality-client.env
```

Each foreign must have its own IP and its own generated credentials.

## Iran install

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover/install-dual-iran.sh -o /root/install-dual-iran.sh
chmod +x /root/install-dual-iran.sh
/root/install-dual-iran.sh
```

The installer asks for the IP and XHTTP/REALITY client values from Foreign #1 and Foreign #2, tests both paths end-to-end, installs the controller, creates the initial sticky 50/50 mapping, safely patches x-ui, and enables automatic health checking.

The existing single XHTTP/Mieru/FRP services are not removed. Dual uses ports `11818` and `11819`, so migration can be tested without destroying the old path.

## CLI

```bash
xhttp-dual status
xhttp-dual sync
xhttp-dual drain f1
xhttp-dual drain f2
xhttp-dual undrain f1
xhttp-dual undrain f2
xhttp-dual rebalance --yes
```

`drain` immediately excludes a foreign and fails its users over to the other healthy node. `undrain` makes it eligible again but does not move existing users back.

Logs:

```bash
journalctl -u xhttp-dual-controller -f
journalctl -u xhttp-dual-f1 -f
journalctl -u xhttp-dual-f2 -f
```

## Uninstall Iran

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover/uninstall-dual-iran.sh -o /root/uninstall-dual-iran.sh
chmod +x /root/uninstall-dual-iran.sh
/root/uninstall-dual-iran.sh
```

This removes only the dual controller/tunnel and its managed x-ui rules/outbounds. It does not remove x-ui or other tunnel systems. x-ui DB backups are intentionally preserved under `/var/lib/xhttp-dual/backups`.

## Foreign uninstall

Run the existing XHTTP foreign uninstaller independently on each foreign server:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover/uninstall-foreign.sh -o /root/uninstall-foreign.sh
chmod +x /root/uninstall-foreign.sh
/root/uninstall-foreign.sh
```

## Notes

- Sticky routing depends on VLESS client `email`, which is the Xray-supported routing identity.
- Existing TCP sessions cannot be moved live between foreign servers. A failover changes routing and restarts x-ui/Xray; clients reconnect through the surviving node.
- The controller is intentionally low-frequency and lightweight: two tiny HTTPS probes every 15 seconds plus two lightweight Xray client processes.
- This build assumes the normal local SQLite x-ui database. It refuses to install if `/etc/x-ui/x-ui.db` is missing unless `XUI_DB_PATH` is explicitly set.
