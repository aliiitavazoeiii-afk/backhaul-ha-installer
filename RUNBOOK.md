# Operations runbook

This file is the command reference for day-to-day operations. Keep operational commands here rather than in troubleshooting chat.

## Transport priority

HAProxy automatically prefers the first healthy end-to-end path in this order:

1. WSSMux primary
2. TCPMux backup
3. plain TCP emergency backup

Health is checked end-to-end against the Foreign health service, not only by checking whether the local Backhaul process is running.

## Normal status

`tunnelctl status`

## Diagnose disconnect / instability

`tunnelctl diagnose`

Equivalent direct command: `tunnel-diagnose`

## Diagnose low speed

Run from Iran: `tunnelctl deep`

This compares WSSMux, TCPMux and plain TCP in both directions.

## Targeted repair

On Foreign: `tunnelctl repair`

Repair restarts only a transport whose control path is reachable but whose data-plane health traffic is stale. HAProxy failover itself does not depend on repair and remains automatic on Iran.

## Logs

`tunnelctl logs`

## Restart all tunnel services

`tunnelctl restart`

## Replace Foreign VPS

Run `tunnelctl replace-foreign NEW_FOREIGN_IP` on Iran, then copy the preserved bundle to the replacement Foreign server and run the Foreign installer. The command updates firewall access for both TCPMux :3080 and plain TCP :3081.

## Replace Iran VPS

Run `tunnelctl replace-iran NEW_IRAN_IP` on Foreign, update backbone DNS, copy the preserved bundle to the replacement Iran server, then run the Iran installer. Both TCPMux and plain TCP client configs are updated.

## Diagnostic-only ports

- WSSMux throughput: Iran `10445` -> Foreign `127.0.0.1:5201`
- TCPMux throughput: Iran `11445` -> Foreign `127.0.0.1:5201`
- plain TCP throughput: Iran `12445` -> Foreign `127.0.0.1:5201`
- Foreign iperf3 listens only on `127.0.0.1:5201`

No public iperf3 firewall port is opened.

## What to share in troubleshooting chat

Prefer sharing only the complete `Diagnosis` section and `Summary` from `tunnel-diagnose`. For speed problems, share the `--deep` result as well.

Do not paste tunnel tokens, Reality private keys, x-ui databases, or certificate private keys.
