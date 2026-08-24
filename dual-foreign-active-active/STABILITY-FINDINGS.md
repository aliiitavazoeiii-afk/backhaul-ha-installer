# Dual-Foreign Stability Findings

## Observed symptom

- VPN can connect but browsing intermittently stalls or becomes very slow.
- Health may show all transports UP at the time of inspection.
- WSS has been observed temporarily returning HTTP=000 and later recovering.
- End-to-end bulk tests through Foreign A data ports 10443 (WSS), 11443 (TCPMux), and 12443 (plain TCP) transferred 10 MiB successfully with matching SHA-256 when the transports were stable.

## Finding 1: health hysteresis was too aggressive

`enable-fast-failover.sh` changed both transport and whole-slot checks to:

```text
inter 1s fall 1 rise 2
```

A single failed health probe could therefore mark a transport or an entire Foreign slot DOWN.

This is materially more aggressive than the Backhaul client's own reconnect timing (`retry_interval = 3`) and can turn short tunnel or health-service hiccups into HAProxy state transitions.

## Finding 2: false-positive transport DOWN could kill live sessions

The WSS primary transport used:

```text
on-marked-down shutdown-sessions
```

With `fall 1`, one failed probe could close established user connections even if the failure was transient.

## Finding 3: recovery window was too short

`rise 2` at a one-second interval allowed a recently flapping transport/Foreign to re-enter service after roughly two successful seconds.

With 24-hour source-IP stickiness, clients previously assigned to that Foreign could immediately return to it after recovery, creating repeated fail/recover/fail churn.

## Finding 4: aggregate slot health is intentionally permissive

A Foreign slot is considered UP while any of WSS, TCPMux, or plain TCP is UP. This is correct for fallback availability, but it means a flapping WSS can repeatedly hand new connections to fallback and then reclaim new connections shortly after recovery.

## Hotfix policy

`apply-stability-hotfix.sh` changes the HAProxy policy without reinstalling Backhaul or rotating tokens:

### Transport level

```text
inter 2s fall 2 rise 5
```

- requires about four seconds of confirmed failure before marking a transport DOWN
- requires about ten seconds of successful checks before returning it to service
- removes transport-level `shutdown-sessions`

### Whole-Foreign level

```text
inter 2s fall 2 rise 10
```

- requires about four seconds of confirmed aggregate failure
- requires about twenty seconds of stable aggregate health before a Foreign returns
- retains `on-marked-down shutdown-sessions` only at whole-slot level so a confirmed dead Foreign causes clients to reconnect to the surviving Foreign

## Next validation

Run repeated data requests through slot ports while intentionally stopping/starting WSS. Validate that:

1. short WSS hiccups no longer kill stable user sessions;
2. WSS failover moves new connections to TCPMux;
3. WSS must remain stable before it is preferred again;
4. complete Foreign failure still redirects reconnects to the other Foreign;
5. no oscillation occurs during repeated WSS stop/start cycles.

The final control-panel build should include a synthetic end-to-end user-data probe in addition to transport and Xray-listener health.
