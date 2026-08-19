# Backhaul HA Installer

Personal one-command installer for the exact tunnel topology tested successfully:

```text
Users -> Iran :443 -> HAProxy
  |-- SNI = backbone domain -> WSSMux control 127.0.0.1:8443
  |-- default -> WSSMux primary :10443 -> Foreign Xray 127.0.0.1:443
  |             health :10444 -> Foreign 127.0.0.1:18090/healthz
  `-- failover -> TCPMux backup :11443 -> Foreign Xray 127.0.0.1:443
                health :11444 -> Foreign 127.0.0.1:18090/healthz

TCPMux control: Iran :3080, firewall-restricted to the Foreign IP.
```

## What is pinned

- Backhaul `v0.7.2` amd64 with binary SHA256 verification.
- WSSMux primary + TCPMux backup.
- HAProxy TCP SNI routing on Iran public `:443`.
- End-to-end HTTP health checks on both transports.
- systemd auto-start.
- UFW matching the tested layout.
- Optional 3x-ui `v2.9.4` launcher on Foreign.
- x-ui database and Reality keys are never overwritten.

## Before install

1. Fresh Ubuntu/Debian amd64 pair.
2. Point the backbone domain A record to the Iran IP.
3. Restore/import your 3x-ui DB separately on Foreign.
4. Main Xray inbound on Foreign must listen on `127.0.0.1:443`.

## Iran first

Run on the Iran server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/install.sh)
```

Choose `Iran` and enter:

- Iran IP
- Foreign IP
- backbone domain

It installs Backhaul, Certbot certificate, HAProxy, both transports, health mappings, UFW, systemd, and generates `/root/backhaul-ha-secrets.env`.

## Foreign

Copy the bundle:

```bash
scp /root/backhaul-ha-secrets.env root@FOREIGN_IP:/root/backhaul-ha-secrets.env
```

Then:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/install.sh) \
  --role foreign --bundle /root/backhaul-ha-secrets.env
```

Optional pinned x-ui launch:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/install.sh) \
  --role foreign --bundle /root/backhaul-ha-secrets.env --install-xui yes
```

## Helper

```bash
tunnelctl status
tunnelctl test
tunnelctl restart
tunnelctl logs
```

## Failover test

Foreign:

```bash
systemctl stop backhaul-wss
```

Iran:

```bash
journalctl -u haproxy -n 30 --no-pager
```

Expect `wss_primary` DOWN and `Running on backup`. Reconnect VPN and verify traffic.

Restore:

```bash
systemctl start backhaul-wss
```

HAProxy should mark WSS primary UP after HTTP 200 health checks.


## Fast replacement when one VPS dies

### Only Foreign changed

On the still-working Iran server:

```bash
tunnelctl replace-foreign NEW_FOREIGN_IP
scp /root/backhaul-ha-secrets.env root@NEW_FOREIGN_IP:/root/backhaul-ha-secrets.env
```

Then install the new Foreign server normally with `--role foreign --bundle ...`.

This keeps the same tokens and only changes the Iran firewall rule for TCPMux `:3080`.

### Only Iran changed

On the still-working Foreign server:

```bash
tunnelctl replace-iran NEW_IRAN_IP
```

Then update the backbone DNS A record to `NEW_IRAN_IP`.

Copy the preserved bundle to the new Iran server:

```bash
scp /root/backhaul-ha-secrets.env root@NEW_IRAN_IP:/root/backhaul-ha-secrets.env
```

On the new Iran server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/install.sh) \
  --role iran --bundle /root/backhaul-ha-secrets.env
```

The same TCPMux/WSSMux tokens are reused, so the Foreign side does not need new secrets.

## Firewall

Iran:
- SSH
- 80/tcp
- 443/tcp
- 3080/tcp only from Foreign IP

Not public:
- 8443
- 10443/10444
- 11443/11444

Foreign:
- SSH
- 2095/tcp by default

Loopback only:
- Xray 443
- health 18090

## Re-run behavior

- Existing tunnel configs are backed up under `/root/backhaul-ha-backups/`.
- Existing tokens are reused from `/root/backhaul-ha-secrets.env`.
- x-ui DB/Reality keys are not modified.
