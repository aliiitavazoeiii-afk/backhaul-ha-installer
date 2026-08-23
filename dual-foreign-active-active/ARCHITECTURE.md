# Architecture

## Data plane

```text
                                      +---------------- Foreign A ----------------+
                                      |  Xray 127.0.0.1:443                        |
                                      +------------------^-------------------------+
                                                         |
                       +-- slot A frontend :15001 -------+
                       |     WSS :10443 (primary)
                       |     TCPMux :11443 (backup)
                       |     TCP :12443 (backup)
                       |
Users -> Iran :443 ----+  vpn_users / balance leastconn
                       |
                       |     WSS :20443 (primary)
                       |     TCPMux :21443 (backup)
                       |     TCP :22443 (backup)
                       +-- slot B frontend :15002 -------+
                                                         |
                                      +------------------v-------------------------+
                                      |  Xray 127.0.0.1:443                        |
                                      +---------------- Foreign B ----------------+
```

The top-level backend never chooses a transport directly. It chooses a **Foreign slot**. Each slot then chooses its own best currently healthy transport. This keeps Foreign-level Active/Active balancing separate from transport-level fallback.

## WSS control routing

Both WSS clients connect to Iran public `:443`, but each uses a different control SNI:

```text
DOMAIN_A -> Iran :443 -> HAProxy SNI -> 127.0.0.1:8443 -> Foreign A WSSMux
DOMAIN_B -> Iran :443 -> HAProxy SNI -> 127.0.0.1:8543 -> Foreign B WSSMux
other SNI/default       -> Active/Active user backend
```

## Port plan

| Function | Foreign A | Foreign B |
|---|---:|---:|
| WSS control server (loopback Iran) | 8443 | 8543 |
| TCPMux control (Iran public, IP-restricted) | 3080 | 3180 |
| plain TCP control (Iran public, IP-restricted) | 3081 | 3181 |
| WSS user data (Iran loopback) | 10443 | 20443 |
| WSS health | 10444 | 20444 |
| TCPMux user data | 11443 | 21443 |
| TCPMux health | 11444 | 21444 |
| plain user data | 12443 | 22443 |
| plain health | 12444 | 22444 |
| slot frontend | 15001 | 15002 |
| slot aggregate health | 15011 | 15012 |

## HA state model

Normal:

```text
Foreign A slot: UP ~50%
Foreign B slot: UP ~50%
```

Foreign A WSS fails:

```text
A slot: TCPMux/Plain fallback keeps A available
B slot: remains active
Top-level remains A/B Active/Active
```

All A transports fail:

```text
A aggregate health -> DOWN -> top-level removes A
B takes 100% of new connections
```

A recovers:

```text
A aggregate health -> UP after rise threshold
new connections are distributed across A/B again
```

## User identity requirement

Because the load balancer operates before Xray authentication, both Foreign Xray instances must recognize the same UUID/user set. The correct long-term control plane is API-based mirroring, not database file copying.
