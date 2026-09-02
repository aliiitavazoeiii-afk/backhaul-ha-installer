# Install commands

Pinned release commit: `c2fbf9456d70220b900093354add393f54c6bc67`

## Iran

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/c2fbf9456d70220b900093354add393f54c6bc67/frp-tunnel-ali-pro/install.sh) iran
```

The Iran installer asks for Iran public IPv4, Foreign public IPv4, a DNS-only tunnel domain pointing directly to Iran, profile name, control port (default 8443), and public user port (default 443). It installs/validates nginx, obtains a Let's Encrypt certificate when needed, configures the WSS edge, FRPS, capacity limits, systemd, and prints a secret pair code.

## Foreign

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/c2fbf9456d70220b900093354add393f54c6bc67/frp-tunnel-ali-pro/install.sh) foreign
```

Paste the pair code printed on Iran and choose the existing local Xray/3x-ui inbound port (default 443). The installer never changes Xray/3x-ui. It creates four independent FRPC shards (6 idle work connections each; total reserve 24) sharing one FRP load-balancer group.

## Health

```bash
frp-ali-health
```

## Diagnostics

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/c2fbf9456d70220b900093354add393f54c6bc67/frp-tunnel-ali-pro/diagnostics.sh)
```

## Uninstall project only

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/c2fbf9456d70220b900093354add393f54c6bc67/frp-tunnel-ali-pro/install.sh) uninstall
```

Uninstall preserves Xray/3x-ui and Let's Encrypt certificates.
