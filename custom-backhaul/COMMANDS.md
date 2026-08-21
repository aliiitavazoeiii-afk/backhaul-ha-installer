# Custom Backhaul v2 — Install & Diagnostics Commands

Validated fresh-install orchestrator commit:

```text
8d26bef39d9870294433c280eb01eac07b290d2b
```

## 1. DNS prerequisites

Create two different A records, both pointing to the Iran server IP:

```text
WSS_DOMAIN       -> IRAN_IP
TCP_TLS_DOMAIN   -> IRAN_IP
```

Example:

```text
bh2.biya2film.top    -> IRAN_IP
edge2.biya2film.top  -> IRAN_IP
```

## 2. Install Iran first

Replace the four placeholders before running:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/8d26bef39d9870294433c280eb01eac07b290d2b/custom-backhaul/install-final-v2.sh) \
  --role iran \
  --iran-ip IRAN_IP \
  --foreign-ip FOREIGN_IP \
  --wss-domain WSS_DOMAIN \
  --tcp-domain TCP_TLS_DOMAIN
```

Example shape:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/8d26bef39d9870294433c280eb01eac07b290d2b/custom-backhaul/install-final-v2.sh) \
  --role iran \
  --iran-ip 1.2.3.4 \
  --foreign-ip 5.6.7.8 \
  --wss-domain bh2.example.com \
  --tcp-domain edge2.example.com
```

## 3. Copy the generated bundle from Iran to Foreign

Run on Iran:

```bash
scp /root/backhaul-ha-secrets.env root@FOREIGN_IP:/root/backhaul-ha-secrets.env
```

Do not paste the bundle contents into chat or public logs.

## 4. Install Foreign

Run on Foreign:

```bash
chmod 600 /root/backhaul-ha-secrets.env

bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/8d26bef39d9870294433c280eb01eac07b290d2b/custom-backhaul/install-final-v2.sh) \
  --role foreign \
  --bundle /root/backhaul-ha-secrets.env
```

## 5. Normal diagnostics

Run on Iran:

```bash
tunnel-diagnose
```

Deep health + throughput diagnostics:

```bash
tunnel-diagnose --deep
```

Expected final state:

```text
WSSMux       OK
TCPMux TLS   OK
plain TCP    OK
Preferred path: WSSMux
0 FAIL
```

## 6. Authoritative transport verifiers

Phase 2 split-TLS / WSS verifier — run on Iran:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/9aaa19300b1a76389695570b0652a2dae19b8743/custom-backhaul/verify-phase2-split-tls.sh)
```

Expected:

```text
23 OK, 0 WARN, 0 FAIL
```

Phase 3 TCPMux-TLS verifier — run on both Iran and Foreign when troubleshooting Phase 3:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/9aaa19300b1a76389695570b0652a2dae19b8743/custom-backhaul/verify-phase3-tcptls.sh)
```

Expected on Iran validated topology:

```text
16 OK, 0 WARN, 0 FAIL
```

## 7. Fast service checks

Iran:

```bash
systemctl --no-pager --full status \
  backhaul \
  backhaul-wss \
  backhaul-tcp \
  backhaul-wss-tls \
  backhaul-tcptls \
  nginx \
  haproxy
```

Foreign:

```bash
systemctl --no-pager --full status \
  backhaul \
  backhaul-wss \
  backhaul-tcp \
  backhaul-tcptls
```

Iran end-to-end health checks:

```bash
curl -fsS --max-time 5 http://127.0.0.1:10444/healthz && echo
curl -fsS --max-time 5 http://127.0.0.1:11444/healthz && echo
curl -fsS --max-time 5 http://127.0.0.1:12444/healthz && echo
```

## 8. Reboot persistence check

After a new pair is fully installed, reboot both servers once:

```bash
reboot
```

After both return, run on Iran:

```bash
tunnel-diagnose --deep
```

The VPN should remain functional and diagnostics should report no failures.
