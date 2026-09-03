# XHTTP + REALITY Tunnel

Independent Iran ↔ Foreign tunnel based only on Xray-core, VLESS, XHTTP and REALITY.

Pinned Xray version: `v26.7.28`.

## Architecture

```text
Application / x-ui
        |
        | SOCKS5 127.0.0.1:10818
        v
Standalone Xray client (Iran)
        |
        | VLESS + XHTTP + REALITY / TCP
        v
Standalone Xray server (Foreign)
        |
        v
Internet
```

The project does not depend on FRP, HAProxy, Nginx, Mieru, Backhaul or an existing x-ui installation.

The Iran service listens only on `127.0.0.1:10818`, so it is not publicly exposed.

## Why the XHTTP config is deliberately small

The official XHTTP quick-start guidance recommends setting only the path in normal deployments and leaving the tuned defaults in place. XHTTP has its own XMUX behavior. Do not add `mux.cool` on top of it.

With REALITY, XHTTP `auto` uses the mode selected by Xray for that transport/security combination. This project therefore does not pile on custom XMUX or padding parameters.

## Foreign installation

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-reality-tunnel/install-foreign.sh -o /root/install-foreign.sh
chmod +x /root/install-foreign.sh
/root/install-foreign.sh
```

Defaults:

- Public port: `443/TCP`
- REALITY target/SNI: `www.microsoft.com:443` / `www.microsoft.com`

Override examples:

```bash
XHTTP_PORT=8443 /root/install-foreign.sh
REALITY_TARGET=example.com:443 REALITY_SNI=example.com /root/install-foreign.sh
FORCE_NEW_CREDENTIALS=1 /root/install-foreign.sh
```

Client connection values are stored at:

```text
/root/xhttp-reality-client.env
```

## Iran installation

Run the installer and enter the values printed/stored by the foreign server:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-reality-tunnel/install-iran.sh -o /root/install-iran.sh
chmod +x /root/install-iran.sh
/root/install-iran.sh
```

Non-interactive form:

```bash
/root/install-iran.sh FOREIGN_IP PORT VLESS_ID REALITY_PASSWORD SHORT_ID SNI XHTTP_PATH
```

Local SOCKS default:

```text
127.0.0.1:10818
```

Use another local port if necessary:

```bash
SOCKS_PORT=11818 /root/install-iran.sh ...
```

## End-to-end test on Iran

```bash
curl --socks5-hostname 127.0.0.1:10818 https://icanhazip.com
```

It should return the public IP of the foreign server (or its egress IP).

## Optional x-ui integration

If x-ui is already installed on the Iran server, add a SOCKS outbound pointing to:

```text
127.0.0.1:10818
```

and route the desired inbound traffic to it.

The standalone installer does not modify x-ui automatically.

## Diagnostics

Iran:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-reality-tunnel/diagnose-iran.sh | bash
```

Foreign:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-reality-tunnel/diagnose-foreign.sh | bash
```

## Uninstall

Iran only:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-reality-tunnel/uninstall-iran.sh -o /root/uninstall-xhttp-iran.sh
chmod +x /root/uninstall-xhttp-iran.sh
/root/uninstall-xhttp-iran.sh
```

Foreign only:

```bash
curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-reality-tunnel/uninstall-foreign.sh -o /root/uninstall-xhttp-foreign.sh
chmod +x /root/uninstall-xhttp-foreign.sh
/root/uninstall-xhttp-foreign.sh
```

The Iran uninstaller does not stop, delete or edit x-ui.

## Important operational notes

- No anti-DPI transport is guaranteed to remain undetectable.
- Keep the same Xray version on both sides.
- Do not enable Xray `mux.cool` on the XHTTP outbound; XHTTP already has XMUX.
- The default REALITY camouflage target is only a generic default. For a carefully tuned deployment, choose a suitable target reachable from the foreign server.
- If port 443 is already occupied on the foreign server, the installer refuses to overwrite the listener. Free it or choose another port.
