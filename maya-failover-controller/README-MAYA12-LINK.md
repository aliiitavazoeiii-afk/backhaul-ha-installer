# Maya1 / Maya2 linked DNS

Maya1 remains the only health/failover decision-maker. Maya2 is a linked Cloudflare DNS record and mirrors every Maya1 MAIN/SPARE/shared-schedule transition.

The patch auto-discovers the Maya2 DNS record by name using the Cloudflare token already stored on the controller host, updates `/etc/maya-failover/config.json`, patches `/opt/maya-failover/controller.py`, and patches `/usr/local/bin/maya-shared-schedule` when present.

It validates Python/Bash syntax, backs up live files, aligns Maya2 to the current Maya1 DNS IP, and rolls files back if the controller fails to restart.

Run as root:

```bash
bash link-maya2-to-maya1.sh maya2.biya2film.top
```
