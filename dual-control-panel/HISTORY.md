# Dual Control Panel / Migration History

## 2026-08-24 — Foreign A replacement incident that shaped the panel

Live topology during the replacement:

- Iran: `5.10.248.50`
- old Foreign A: `193.57.9.144`
- replacement Foreign A: `193.57.9.55`
- Foreign B: `193.57.9.192`

The old A became unusable and a replacement was introduced while B continued serving users.

### Safe sequence validated

1. `foreign_a` was marked `disabled` in HAProxy so all new/reconnecting users went to B.
2. Existing A transport tokens were preserved; no Iran reinstall/token rotation was performed.
3. The A bundle was copied and only `FOREIGN_IP` was changed to the replacement IP.
4. The new A IP was allowed on Iran's A TCPMux/plain-TCP control ports.
5. Xray/X-UI was prepared on the replacement A with the intended `127.0.0.1:443` inbound.
6. Replacement A Backhaul was installed from the preserved-token bundle.
7. WSS health became healthy immediately, but TCPMux and plain TCP remained unhealthy.

### Important diagnosis

The A WSS/MUX/TCP token SHA-256 values were compared between Iran and the replacement Foreign and all three matched exactly, ruling out token mismatch.

A raw TCP payload test on a temporary Iran port succeeded from the replacement Foreign, ruling out a general TCP/IP filtering failure on the new Foreign IP.

Iran socket inspection then showed old established control channels still attached to `193.57.9.144` on both A direct control ports (`3080` and `3081`). The new `.55` clients reached Iran but Backhaul reset their protocol handshake because the server still had stale control-channel state for the old A.

Validated fix while A was drained:

```bash
systemctl restart dual-bh-a-mux dual-bh-a-tcp
```

After restarting the drained slot's server-side control services and reconnecting the replacement client, all A transports became healthy:

- A WSS: OK
- A TCPMux: OK
- A plain TCP: OK
- A aggregate slot: OK

B remained healthy throughout.

### User synchronization during replacement

Foreign B temporarily acted as the bootstrap user source and mirrored 155 VLESS clients to the new A. The resulting normalized user set matched with no pending additions/updates/extras and hash verification succeeded.

The final management direction is intended to be A -> B.

### Control-panel design consequence

The new `dualctl replace-a` / `replace-b` workflow therefore performs these operations in order:

1. drain the target slot
2. update the preserved-token bundle with the replacement IP
3. firewall the new control IP
4. block the old Foreign control source
5. restart only the drained Iran-side Backhaul slot to clear stale control state
6. optionally SCP the updated bundle to the replacement Foreign
7. keep the slot disabled until health is verified
8. activate explicitly after validation

This behavior exists specifically to avoid repeating the stale-control-channel failure found during the `.144 -> .55` migration.

## Control panel branch

Branch: `agent/dual-control-panel`

The panel is a management/orchestration layer around the validated Dual data-plane stack. It does not merge `custom-backhaul-v2` or WSS Stealth.

Current panel command:

```bash
dualctl
```

Fresh hosts use the interactive role/setup wizard. Existing Dual hosts are imported into panel state without reinstalling the data plane.

Current first-build limitation: the validated fresh-install engine still requires WSS domains. A no-domain MUX/TCP-only installation profile is intentionally deferred until separately validated.
