# Dual WSS Stealth

Clean two-Foreign topology using only the validated Custom Backhaul v2 WSS Stealth transport.

## Design

```text
                         IRAN :443
                            |
                         HAProxy
                 +----------+----------+
                 |                     |
       SNI Domain A control   SNI Domain B control
                 |                     |
          stunnel A :9443       stunnel B :9444
                 |                     |
           nginx A :9080         nginx B :9081
                 |                     |
       Backhaul A WSMux :18080  Backhaul B WSMux :28080
                 |                     |
         data :10443             data :20443
         health :10444           health :20444
                 \                     /
                  \--- vpn_users -----/
                      round-robin
                    source-IP sticky
```

Foreign A and B each run one Custom Backhaul v2 `wssmux` client and connect outbound to their own domain on Iran. Xray remains local on each Foreign at `127.0.0.1:443`.

There is deliberately no TCPMux or plain TCP fallback.

## Why

The previous three-transport Dual build could report the whole Foreign healthy when a fallback transport was only partially healthy. TCPMux was observed accepting TCP immediately while intermittently stalling HTTP payload for more than three seconds. A WSS failure could therefore move users onto a degraded fallback. This build removes that failure mode instead of adding more health/failover complexity.

## Health policy

HAProxy checks each Foreign through that same Foreign's WSS Stealth tunnel:

- A data: `127.0.0.1:10443`
- A health: `127.0.0.1:10444`
- B data: `127.0.0.1:20443`
- B health: `127.0.0.1:20444`
- `inter 2s`
- `fall 3` (about six seconds before removal)
- `rise 5` (about ten seconds stable before return)
- `on-marked-down shutdown-sessions` only at the whole-Foreign level

The Foreign health process also verifies that Xray accepts TCP on `127.0.0.1:443`.

## Clean old project

Run on Iran and both Foreign hosts:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-wss-stealth/dual-wss-stealth/clean-project.sh)
```

The cleanup preserves X-UI/Xray, SSH and Let's Encrypt certificates. It backs up tunnel state before deletion.

## Fresh Iran install

Both WSS domains must resolve to the Iran public IP.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-wss-stealth/dual-wss-stealth/install.sh) \
  --role iran \
  --iran-ip IRAN_IP \
  --domain-a DOMAIN_A \
  --domain-b DOMAIN_B
```

Iran generates two secret bundles:

```text
/root/dual-stealth-a.env
/root/dual-stealth-b.env
```

Never paste those files into chat or public logs.

## Foreign A

Copy A's bundle directly to Foreign A, then:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-wss-stealth/dual-wss-stealth/install.sh) \
  --role foreign \
  --bundle /root/dual-stealth-a.env
```

## Foreign B

Copy B's bundle directly to Foreign B, then:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-wss-stealth/dual-wss-stealth/install.sh) \
  --role foreign \
  --bundle /root/dual-stealth-b.env
```

## Management

Iran:

```bash
stealthctl status
stealthctl diagnose
stealthctl drain-a
stealthctl activate-a
stealthctl drain-b
stealthctl activate-b
stealthctl restart
stealthctl logs
```

Foreign:

```bash
stealthctl status
stealthctl restart
stealthctl logs
```

Replacing a Foreign IP no longer requires editing Iran tunnel configs. Stop the old Foreign client, copy that slot's bundle to the replacement Foreign, install it, and wait for its end-to-end health to turn green.

## Scope

This first clean build intentionally does not merge the old Dual TCP/TCPMux code or the old multi-transport failover scripts. User synchronization/panel automation can sit above this data plane without changing the transport topology.
