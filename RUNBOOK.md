# Operations runbook

This file is the command reference for day-to-day operations. Keep operational commands here rather than in troubleshooting chat.

## Normal status

`tunnelctl status`

## Basic end-to-end test

`tunnelctl test`

## Logs

`tunnelctl logs`

## Restart tunnel services

`tunnelctl restart`

## Diagnose disconnect / instability

`tunnel-diagnose`

## Diagnose low speed

Run from Iran: `tunnel-diagnose --deep`

## Diagnostic setup / update

Run the repository `enable-diagnostics.sh` on Foreign first, then Iran. It installs or updates `/usr/local/bin/tunnel-diagnose` and the private throughput-test endpoints.

## Replace Foreign VPS

Use the existing `tunnelctl replace-foreign NEW_FOREIGN_IP` workflow on Iran, copy the preserved bundle to the replacement Foreign server, then run the Foreign installer.

## Replace Iran VPS

Use the existing `tunnelctl replace-iran NEW_IRAN_IP` workflow on Foreign, update backbone DNS, copy the preserved bundle to the replacement Iran server, then run the Iran installer.

## What to share in troubleshooting chat

Prefer sharing only the complete `Diagnosis` section and `Summary` from `tunnel-diagnose`. For speed problems, share the `--deep` result as well.

Do not paste tunnel tokens, Reality private keys, x-ui databases, or certificate private keys.