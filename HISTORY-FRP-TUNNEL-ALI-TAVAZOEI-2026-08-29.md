# FRP Tunnel / Aegis / Spare Failover — Complete Chat Handoff

**Date frozen:** 2026-08-29

**Owner:** Ali Tavazoei

**Repository:** `aliiitavazoeiii-afk/backhaul-ha-installer`

**Purpose of this file:** This is the canonical handoff for continuing the VPN tunnel project in a new ChatGPT conversation. The next assistant should read this file **before suggesting commands or changing code**. The user explicitly does not want to repeat the topology, prior experiments, bugs, or operational constraints.

---

# 0. READ THIS FIRST — HOW THE NEXT CHAT SHOULD CONTINUE

The user will likely say something like:

> برو اول `HISTORY-FRP-TUNNEL-ALI-TAVAZOEI-2026-08-29.md` رو کامل بخون و از همونجا ادامه بده.

The next assistant should:

1. Read this entire file.
2. Inspect the current GitHub repository before modifying anything.
3. Do **not** assume a server pair or IP unless it is explicitly identified in the current request; there are multiple production/test pairs in this history.
4. Do **not** perform blind restarts on production.
5. Give one safe operational step at a time when debugging live traffic.
6. Back up config before destructive changes.
7. Pin installation URLs to immutable commits, not moving branches.
8. Do not ask the user for passwords/private keys/API secrets in chat.
9. 3x-ui/Xray is managed by the user. Tunnel installers must not silently install, alter, synchronize, or overwrite 3x-ui unless the user explicitly asks.
10. Do not call an experimental tunnel production-ready until it has survived real traffic.
11. User prioritizes: **stability first, no visible freezes, good speed, low disconnects, strong resistance to filtering/DPI, simple recovery.**
12. A claim like “zero disconnect forever” is not technically defensible. Design for graceful degradation, rapid recovery, and no single-packet/burst-induced session death.

The immediate next major engineering task requested by the user is documented in **Section 11**.

---

# 1. USER'S NETWORK / SERVICE CONTEXT

The user runs a VPN service with roughly hundreds of provisioned users; earlier numbers were around ~100 active and later ~320 users in the management dataset. Typical simultaneous online load has been around **20–50 users**, but the tunnel can see hundreds of concurrent TCP streams because apps such as Instagram, browsers, Telegram, etc. open many sockets per user.

Important user preferences:

- Production tunnel servers should remain lightweight.
- Avoid installing databases/monitoring agents on production VPN servers unless necessary.
- User wants straightforward copy/paste commands labeled by exact server role/IP.
- During incidents, do not send a giant diagnostic shotgun. One safe step at a time.
- User is highly sensitive to user-facing outages. A restart that breaks all existing streams is not an acceptable “test” unless there is a rollback plan and the user explicitly accepts it.
- User has repeatedly rejected UDP-based solutions for this environment because Hysteria2/UDP produced severe disconnect/reconnect behavior in Iran.
- User prefers TCP-based transports where possible.

---

# 2. IMPORTANT SERVER PAIRS / TOPOLOGIES SEEN IN THIS CHAT

There are multiple pairs in history. **Do not merge them mentally.**

## 2.1 Current Aegis pair used in the latest freeze debugging

Latest verified foreign host:

- Foreign: `84.32.231.174`
- Hostname shown in shell: `glowing-akita`
- Iran edge: `94.184.4.38`
- Aegis domain: `ag2.biya2film.top`

Verified client config during the incident:

```text
remote_addr = ag2.biya2film.top:443
edge_ip     = 94.184.4.38
pool        = 4
```

The original Aegis client process was:

```text
/usr/local/bin/aegis -role client -config /etc/aegis-single/client.json
```

An extra carrier process was later added:

```text
/usr/local/bin/aegis -role client -config /etc/aegis-single/client-extra.json
```

At the time of the latest verified ownership check:

- `aegis-client.service` = active
- `aegis-client-extra.service` = active
- original client contributed 4 carriers
- extra client contributed 12 carriers
- total live Aegis carrier TCP sockets = **16**

This was confirmed using `ss -Htnp state established dst 94.184.4.38:443`, and all 16 sockets were owned by one of the two Aegis PIDs.

## 2.2 Other Aegis pair seen earlier

Another production pair existed:

- Iran: `185.215.230.207`
- Foreign: `193.57.9.239`
- domain: `ag1.biya2film.top`

This pair generated a previous live freeze capture with roughly **941 established user→Aegis connections** on Iran `:10443`, while Aegis readiness remained UP and carrier reconnect events were absent in the capture window.

Do not accidentally use the `.207/.239` pair when the user is currently working on `.38/.174`, and vice versa.

## 2.3 Old / unrelated topology

Old topology mentioned in history:

- Iran `185.215.230.207`, hostname `general2`
- Foreign Primary `193.57.9.25`, hostname `s1`
- Foreign Backup `193.57.9.55`

This is separate from the current `84.32.231.174 ↔ 94.184.4.38` debugging pair.

## 2.4 Deleted / abandoned servers

- Old Foreign Backup `84.32.185.247` was deleted and should not be assumed available.
- `193.57.9.184` was suspected filtered/abandoned; ignore unless user reintroduces it.

---

# 3. AEGIS SINGLE-PRIMARY ARCHITECTURE THAT WAS DEPLOYED

Conceptual path:

```text
USER
  ↓
Iran public :443
  ↓
HAProxy
  ↓
127.0.0.1:10443
  ↓
Aegis server
  ↓
WSS/TLS carrier connections initiated from Foreign
  ↓
Foreign Aegis client
  ↓
Foreign Xray target 127.0.0.1:443
```

Iran readiness endpoint:

```text
127.0.0.1:10444
```

Carrier ingress on Iran:

```text
nginx 127.0.0.1:9443
    ↓
Aegis server 127.0.0.1:18080
```

Known HAProxy backend shape used in the single-primary design:

```haproxy
backend user_gateway
    mode tcp
    option redispatch
    retries 2
    server aegis_primary 127.0.0.1:10443 check port 10444 inter 2s fall 3 rise 3 on-marked-down shutdown-sessions
```

There is **no direct active-active backup** in this simplified production architecture.

---

# 4. AEGIS SOURCE / INSTALLER PINS — DO NOT LOSE THESE

Repository:

```text
aliiitavazoeiii-afk/backhaul-ha-installer
```

Frozen Aegis engine commit:

```text
269494a90c1ab38be4338eb1314de47f6dbc6fe1
```

Aegis version at that engine state:

```text
0.2.0
```

Single-primary installer commit:

```text
ef0e8a44065ca537c976858c9f9ae8f7a503313c
```

Immutable installer URL used:

```text
https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/ef0e8a44065ca537c976858c9f9ae8f7a503313c/aegis-single/install.sh
```

Old direct-backup installer that should **NOT** be reused:

```text
2be6343fb6af4e99d5c019eaf698e06047388b73
```

Old CLI wrapper v2.0.0 commit:

```text
6dd9658fbac016ca257dfcd4fd6cb3dbd9f24020
```

The installer was intentionally designed not to install/modify 3x-ui. Foreign target is the user’s existing Xray listener, usually:

```text
127.0.0.1:443
```

---

# 5. WHAT THE AEGIS ENGINE ACTUALLY DOES — IMPORTANT FOR FREEZE ANALYSIS

These facts are from the frozen source at commit `269494...`.

## 5.1 Client pool behavior

- `Pool <= 0` defaults to `4`.
- Config maximum pool accepted by client is `32`.
- Each pool slot runs its own `sessionLoop`.
- Each carrier is one long-lived TCP/TLS/WSS connection.
- TCP dialer KeepAlive: around 30s.
- Carrier reconnect uses exponential backoff up to about 15s.

## 5.2 Health behavior

- Local target health interval is around 2s in the deployed config path.
- Client probes the local Xray target.
- After two consecutive health failures, client marks local target DOWN and closes all carriers.
- This can be catastrophic if the health target has a short transient failure; however in the freeze captures there were no corresponding carrier reconnect/offline events, so this was not the main explanation for the observed Instagram/Chrome freezes.

## 5.3 Server carrier limits / scheduling

- `maxServerCarriers = 32`
- `maxStreamsPerCarrier = 1024`
- Server selects carriers using round-robin candidate ordering.
- It does **not** score carriers by RTT, queue depth, congestion, packet loss, or stream count.

This means a degraded/busy carrier can still receive new streams.

## 5.4 Critical per-stream queue behavior

Frozen source values:

```go
const streamQueueDepth = 32
const carrierWriteTimeout = 8 * time.Second
```

Each stream state has:

```go
writeCh chan []byte
```

with capacity 32.

The important behavior is that `enqueue()` is **non-blocking**. If the channel is full, it immediately returns false.

Both server and client read loops do roughly this logic:

```text
if !st.enqueue(payload):
    send TypeClose
    delete stream
```

So when an app generates a burst faster than the per-stream writer can drain, a full 32-frame queue can cause **that individual TCP stream to be killed**, while the carrier itself remains connected and the overall VPN stays “UP”.

This is a very important architectural weakness because it matches the user-visible symptom:

```text
Instagram / video / page stream bursts
        ↓
per-stream queue fills temporarily
        ↓
Aegis closes only that stream
        ↓
app freezes / retries
        ↓
new TCP connection is created
        ↓
traffic resumes a few seconds later
```

This is not proof that every freeze is queue overflow because the frozen source did not log a dedicated “queue full” event. But it is a real failure mode in the code and is consistent with the observed behavior.

## 5.5 Shared TCP head-of-line risk

Multiple independent user streams are multiplexed inside one TCP carrier.

Therefore packet loss / RTO / congestion on one carrier can temporarily delay multiple logical streams assigned to that carrier. This is classic TCP-over-multiplexing head-of-line behavior.

Increasing carrier count can reduce concentration but **does not eliminate** the architectural problem.

---

# 6. LIVE FREEZE INVESTIGATION — WHAT WAS ACTUALLY OBSERVED

User’s recurring complaint:

- Aegis has generally performed better than the other tunnels tried.
- Main remaining defect: Instagram/Reels/video or browser traffic can freeze for a few seconds and then resume.
- Sometimes frequent, sometimes rare.
- User sometimes says “ghat shod” for this freeze; it does not necessarily mean the entire VPN disconnected globally.

## 6.1 First useful capture on `.207/.239`

During a freeze:

- Aegis server active.
- nginx active.
- HAProxy active.
- readiness UP.
- no carrier reconnect/offline event captured.
- HAProxy kept accepting/handling many sessions.
- around 941 established connections to Aegis local port `:10443`.
- bursts of messages like `stream <id> read ended: ... use of closed network connection` were seen.

Interpretation: did not look like a whole backend outage. Focus moved toward individual stream / multiplex transport behavior.

## 6.2 Carrier expansion experiment on `.38/.174`

Original client:

```text
pool = 4
```

A second additive service was created without stopping the original:

```text
/etc/aegis-single/client-extra.json
pool = 12
```

Service name:

```text
aegis-client-extra.service
```

Result: total live carrier sockets = **16**.

Important: this was verified by process/socket ownership. It was not merely an `ss` count guess.

## 6.3 Freeze still occurred with 16 carriers

During a later live capture on Foreign `84.32.231.174` → Iran `94.184.4.38`:

- 16 Aegis carrier sockets existed.
- carrier disconnect/reconnect events were absent in the relevant log window.
- RTTs were mostly around ~80–90ms.
- some carrier `Send-Q` values rose into tens or >100KB during bursts and then drained.
- global TCP retrans/timeout counters increased only modestly over the captured seconds, not enough to look like a full route collapse.

Examples during the freeze window included carrier Send-Q values around:

```text
~140 KB
~135 KB
~114 KB
~69 KB
~52 KB
```

and changing from second to second.

Global counters over a few seconds moved only modestly, e.g. retrans increased by tens rather than exploding system-wide.

Interpretation:

- “only 4 carriers” was not sufficient as an explanation.
- increasing carriers helped distribute load but did **not** eliminate the freeze.
- data was more consistent with transient per-carrier backlog / HOL / stream-level behavior than a global carrier reconnect.

## 6.4 A proposed 32-carrier mitigation

A later recommendation was to add another 16-carrier service so total would reach the server maximum of 32:

```text
original 4
+ extra 12
+ extra2 16
= 32 total
```

This was proposed as a **mitigation**, not a final fix.

Do not assume the third `extra2` service was actually deployed unless verified on the live server in the new chat.

The correct way to verify before any action is:

```bash
systemctl --type=service --state=running --no-pager | grep -i aegis
ps -eo pid,ppid,lstart,cmd | grep '[a]egis'
ss -Htnp state established dst <IRAN_IP>:443
```

Do not stop any extra carrier service during peak traffic without considering that streams assigned to its carriers will be dropped.

---

# 7. AEGIS-T EXPERIMENT — DO NOT CONFUSE WITH CURRENT AEGIS

A separate experimental project called **Aegis-T** was created/tested.

Concept:

- TCP-only reverse connection Foreign→Iran.
- no WebSocket.
- one user TCP stream mapped to one dedicated carrier TCP.
- warm idle authenticated carrier pool.
- TLS + HTTP/1.1 bootstrap.
- HMAC timestamp/nonce/replay protections.
- random path/header padding.
- health Foreign `127.0.0.1:443`.
- Iran readiness `127.0.0.1:10444`.
- does not modify 3x-ui.

Branch historically used:

```text
agent/aegis-t-v1
```

Hardened engine pin:

```text
a1449de47fe13a20aacfe22e56412a4e50f9854a
```

There was an installer problem because one script referenced a nonexistent Go 1.26.5 tarball. User eventually installed Go successfully using:

```bash
snap install go --classic
```

which yielded a newer Go release at the time.

Canary test pair:

- Iran `5.10.248.50`
- Foreign `31.57.26.176`
- domain `agt1.biya2film.top`

Aegis-T initially worked, including user-facing `:443` after HAProxy conversion, but later **cut out under real use and users complained**.

Therefore:

- Do not call Aegis-T production-proven.
- Do not move production back to Aegis-T unless user explicitly decides to resume that branch and fixes are validated.

---

# 8. NPV / CHROME TESTS THAT OCCURRED AFTER THE FREEZE DEBUGGING

The user uses NPV Tunnel on Android and encountered a browser symptom where Google/domain pages would not open while direct IP traffic could work.

Observed UI/settings from screenshots:

- Per App Proxy was OFF, so unticked Chrome in the app list was not itself the cause.
- A direct request to a Cloudflare IP endpoint worked:

```text
https://1.1.1.1/cdn-cgi/trace
```

- A domain request such as:

```text
https://www.cloudflare.com/cdn-cgi/trace
```

failed with `ERR_CONNECTION_CLOSED`.

This was important because it did not look like a simple `ERR_NAME_NOT_RESOLVED` DNS failure.

Some client-side experiments proposed:

- Local DNS ON.
- Fake DNS OFF.
- remote DNS DoH such as `https://1.1.1.1/dns-query`.
- MTU reduced from 1500 to 1400 for testing.
- inspect `V2RAY · CONNECTION`, domain strategy, IPv4/IPv6 preference.
- try `UseIPv4` / `PreferIPv4` and disable/prevent IPv6 if NPV exposed such settings.

This thread was **not conclusively resolved** before the conversation moved to spare server design.

Do not use the Chrome symptom alone to declare Aegis broken; direct-IP success showed that at least some tunnel path remained alive.

---

# 9. MAYA1 / MAYA3 SHARED SPARE DESIGN — USER’S DESIRED FAILOVER ARCHITECTURE

The user has two separate VPN service groups called:

```text
Maya1
Maya3
```

Each normally has its own:

```text
Iran primary
Foreign primary
```

The user wants **one shared Iran spare + one shared Foreign spare**.

Important assumption explicitly stated by the user:

> Only one Maya needs the spare at a time. Maya1 and Maya3 do not need to occupy the shared spare simultaneously.

Therefore one public `Iran-Spare:443` slot is enough.

## 9.1 Foreign spare inbound layout requested

The user wants both inbound environments permanently present on the same Foreign-Spare server using different loopback addresses, for example:

```text
Maya1 inbound:
127.0.0.1:443

Maya3 inbound:
127.0.0.3:443
```

These can coexist because the local IP addresses differ even though both use port 443.

The user manages these Xray/3x-ui inbounds. The tunnel/failover software should not rewrite them without explicit instruction.

## 9.2 Iran spare behavior

Iran-Spare exposes one public listener:

```text
0.0.0.0:443
```

At any moment it is assigned to one profile:

```text
MAYA1
or
MAYA3
```

Conceptually:

```text
MAYA1 failover:
User → maya1 subdomain → Iran-Spare:443 → tunnel → Foreign-Spare → 127.0.0.1:443
```

```text
MAYA3 failover:
User → maya3 subdomain → Iran-Spare:443 → tunnel → Foreign-Spare → 127.0.0.3:443
```

Because only one profile uses the spare at a time, there is no need to distinguish Maya1 vs Maya3 by SNI at the spare. The selected spare profile decides the target.

## 9.3 Desired selector command

A useful interface proposed:

```bash
maya-spare maya1
maya-spare maya3
maya-spare status
```

Expected semantics:

```text
maya-spare maya1
```

should:

1. verify Maya1 Foreign-Spare target (`127.0.0.1:443`) is reachable;
2. stop/disable the other spare route only if necessary;
3. activate Maya1 tunnel/profile on public Iran-Spare `:443`;
4. verify end-to-end health;
5. only then declare READY.

Same for Maya3 targeting `127.0.0.3:443`.

A status response could be:

```text
ACTIVE SPARE: MAYA1
Iran :443       READY
Tunnel          UP
Foreign target  127.0.0.1:443 UP
```

---

# 10. TELEGRAM + CLOUDFLARE AUTOMATIC FAILOVER DESIGN DISCUSSED

The user asked whether a Telegram bot/watchdog could check Maya1 and Maya3 every 30 seconds, detect filtering/outage, and automatically change the Cloudflare DNS record of the failed Maya to the Iran-Spare IP.

Answer: yes, but the health test should not be only ICMP ping.

## 10.1 Correct health logic

Use layered checks such as:

```text
1. ICMP reachability (diagnostic only)
2. TCP :443 reachability
3. end-to-end application/service health through the actual tunnel/protocol
```

Failover should be based primarily on #3, not just ping.

Example failure threshold discussed:

```text
check every 30 seconds
3 consecutive failures
≈ 90 seconds before failover
```

This prevents one transient packet loss from moving all users.

## 10.2 Important DNS health-check rule

The watchdog must continue checking the **Primary IP directly**, not the public Maya domain after failover.

Why:

If `maya1.example.com` is changed to the spare and the watchdog checks the same domain, it would see the spare as healthy and incorrectly conclude that the primary recovered.

Therefore maintain separate state:

```text
MAYA1_PRIMARY_IP:443
MAYA3_PRIMARY_IP:443
```

while Cloudflare DNS is a separately managed routing decision.

## 10.3 Safe failover sequence

For Maya1 example:

```text
Primary check fails 3 times
    ↓
prepare/activate Maya1 profile on spare
    ↓
verify Foreign-Spare 127.0.0.1:443
    ↓
verify end-to-end spare path
    ↓
ONLY IF READY: update Cloudflare maya1 record → Iran-Spare IP
    ↓
send Telegram alert
```

Never update DNS first and hope the spare is ready later.

## 10.4 Failback / anti-flapping

Do not automatically switch back to primary after one successful check.

Suggested policy:

```text
Failover: 3 consecutive FAILs
Recovery: primary stable for ~10 minutes
```

Even safer production UX:

```text
✅ MAYA1 PRIMARY RECOVERED
Stable for: 10 min

[ Return to Primary ]
[ Keep Spare ]
```

So failover can be automatic, while failback can require user approval.

## 10.5 Cloudflare credentials

Use a scoped **Cloudflare API Token** with only the required DNS-edit permission for the relevant zone/records.

Do not use or request the global API key in chat.

Store token locally with restrictive permissions/environment credentials.

## 10.6 Telegram bot architecture

Best design discussed:

- failover watchdog = independent systemd service;
- Telegram bot = UI/control/notification layer;
- failover must still function if Telegram Bot API itself is unavailable.

Suggested commands/UI:

```text
/status
```

Possible output:

```text
MAYA1
Primary: 🟢 UP
Current DNS: PRIMARY
Spare: READY

MAYA3
Primary: 🟢 UP
Current DNS: PRIMARY
Spare: READY

SPARE
Active profile: NONE
```

Manual actions:

```text
[MAYA1 → SPARE]
[MAYA3 → SPARE]
[MAYA1 → PRIMARY]
[MAYA3 → PRIMARY]
```

The system must enforce the resource constraint that only one Maya can occupy the single shared public Iran-Spare `:443` at a time.

If both primaries fail simultaneously, the policy must be explicit (for example, preserve whichever Maya is already on spare and alert that the second cannot automatically fail over). Do not silently steal the spare from one live group to rescue the other.

---

# 11. THE NEXT MAJOR PROJECT REQUEST: FINAL CUSTOM FRP TUNNEL

This is the user’s latest engineering request and should be treated as the next project milestone.

The user asked to take the **FRP tunnel concept**, analyze it again, remove its weaknesses, improve DPI/filtering resistance, eliminate/reduce freezing, make it robust and stable, and turn it into a polished deployable custom project.

Desired product/project name exactly in spirit:

```text
FRP Tunnel - Ali Tavazoei Custom Version
```

The user wrote the name approximately as:

```text
frp tunnel-ali tavazoei cutom version
```

Use a cleaned display name while preserving the owner branding.

## 11.1 Core goals

The final project should prioritize:

1. **High stability under real multi-user traffic.**
2. **No burst-induced application freezes where avoidable.**
3. **Strong resistance to simple DPI/fingerprinting/filtering.**
4. **Predictable behavior under packet loss / transient congestion.**
5. **Fast reconnect without global session collapse.**
6. **No fragile active-active complexity unless explicitly needed.**
7. **Minimal operational dependency footprint.**
8. **Safe upgrades and rollback.**
9. **Clear diagnostics and health status.**
10. **Do not touch 3x-ui automatically.**

## 11.2 Important engineering lesson from Aegis that must carry into FRP design

Do **not** reproduce the Aegis failure pattern where a short per-stream non-blocking queue fills and the logical user stream is immediately destroyed.

A better design needs explicit backpressure / flow control or a bounded strategy that does not convert a short burst into a forced TCP close.

Likewise, avoid concentrating too many unrelated streams behind one congestion-controlled TCP carrier without considering HOL.

Potential design principles to evaluate (not automatically implement blindly):

- multiple independent carriers/shards;
- stable stream-to-carrier affinity;
- load-aware carrier selection rather than blind round-robin;
- queue/backpressure metrics;
- congestion-aware failover of **new streams** without killing existing streams;
- optional carrier draining before maintenance;
- jittered reconnects to avoid reconnect storms;
- explicit max-stream and max-memory bounds;
- per-stream fairness so one large download/video does not starve interactive traffic;
- keepalive thresholds tolerant of brief network jitter;
- no “two transient local health misses → close every carrier” behavior unless the user intentionally configures it.

## 11.3 DPI-resistance requirement

The user explicitly wants this project more resistant to filtering/DPI.

Design goals should focus on making the transport resemble legitimate, well-formed traffic and avoiding a static, trivial signature, while preserving reliability.

Important: do not sacrifice stability just to add random obfuscation.

Things to assess in the new project:

- TLS correctness and normal TLS behavior;
- realistic HTTP/TLS framing if such a wrapper is used;
- avoiding constant unique magic bytes visible before encryption;
- random/non-static request paths where appropriate;
- sane handshake sizes/timings;
- legitimate SNI/certificate flow where applicable;
- configurable domains/hostnames;
- reconnect jitter;
- avoid obviously periodic identical beacon patterns;
- no malformed protocol tricks that break on middleboxes;
- protect authentication/replay without adding a deterministic fingerprint.

The user has already rejected UDP/QUIC-first approaches for this Iran environment due prior Hysteria2 instability, so TCP-first should be the default unless new evidence changes the decision.

## 11.4 Installation experience requested

The installer should be interactive and ask everything necessary in terminal, including role-specific data.

Examples of things it should prompt for where relevant:

### Iran role

- Iran public/bind IP or interface context.
- public user-facing port (normally 443).
- Foreign peer IP/domain.
- tunnel authentication credential generation/confirmation.
- domain used for the tunnel/cover/endpoint if required.
- local target/listener mappings.
- optional spare profile name (Maya1/Maya3/etc.).

### Foreign role

- Foreign public IP context.
- Iran peer/domain.
- target inbound address, e.g. `127.0.0.1:443` or `127.0.0.3:443`.
- domain/SNI/certificate requirements if used.
- profile name.

The installer should validate input before writing services.

At the end it should automatically run health checks and print a clear final status.

## 11.5 Desired final terminal health output

Example style:

```text
╭──────────────────────────────────────────────╮
│ FRP Tunnel - Ali Tavazoei Custom Version    │
╰──────────────────────────────────────────────╯

Role:              FOREIGN
Profile:           MAYA1
Peer:              94.x.x.x:443
Local target:      127.0.0.1:443
Service:           ✅ ACTIVE
Tunnel handshake:  ✅ OK
Target health:     ✅ OK
Carrier(s):        ✅ 8/8
RTT:               82 ms
Recent reconnects: 0

STATUS: 🟢 READY FOR TRAFFIC
```

If not ready, it must explain **why**, not just print FAIL.

## 11.6 Management panel requested

The user explicitly wants a **beautiful panel** for the tunnel.

Project/panel display name:

```text
FRP Tunnel - Ali Tavazoei Custom Version
```

The panel should focus on tunnel operations, not replace 3x-ui.

Useful dashboard cards:

- Iran endpoint status.
- Foreign endpoint status.
- active profile (Maya1 / Maya3 / normal).
- tunnel uptime.
- current carriers/connections.
- current active logical streams if available.
- throughput RX/TX.
- RTT.
- reconnect count.
- recent health failures.
- queue/backpressure warnings.
- packet-loss/retransmission indicators where safely measurable.
- target Xray health.
- public `:443` readiness.
- spare status.

Useful actions:

- status / diagnostics.
- activate spare profile Maya1.
- activate spare profile Maya3.
- safe drain/restart where supported.
- view logs.
- run end-to-end health test.
- backup config.
- rollback version.

Do not include dangerous one-click destructive actions without confirmation/rollback.

## 11.7 Installer/menu UX

A command/menu could look like:

```text
frp-ali
```

with options such as:

```text
1) Install Iran Node
2) Install Foreign Node
3) Add / Edit Profile
4) Switch Spare Profile
5) Health Check
6) Live Status
7) Diagnostics
8) Backup Config
9) Upgrade
10) Rollback
11) Uninstall
```

For the shared spare environment, profiles should support e.g.:

```text
MAYA1 → Foreign target 127.0.0.1:443
MAYA3 → Foreign target 127.0.0.3:443
```

and enforce that only one profile owns the public Iran spare slot at once.

## 11.8 Final project quality expectations

Before telling the user “done”, the next assistant should:

- inspect the existing repository layout;
- decide whether to build in a new directory/branch instead of overwriting stable Aegis code;
- write tests for config parsing, handshake, reconnection, queue behavior, and profile switching;
- make systemd units restart-safe;
- make uninstall only remove files created by this project;
- preserve existing Xray/3x-ui;
- provide immutable install URL pinned to a final commit;
- include a runbook;
- include diagnostics commands;
- include rollback instructions;
- test syntax/build via CI or local compilation before asking the user to deploy;
- clearly label experimental vs production-ready pieces.

---

# 12. IMPORTANT DESIGN WEAKNESSES TO AVOID IN THE NEW FRP CUSTOM VERSION

This section is deliberately explicit so the new chat does not reintroduce already-seen problems.

## 12.1 Do not kill a stream immediately on a tiny queue overflow

Aegis currently has a 32-frame non-blocking stream queue and closes the stream if full.

New design should use controlled backpressure/fairness and bounded memory instead of immediate logical stream destruction on ordinary bursts.

## 12.2 Do not use blind round-robin only

A carrier with high queue/latency/congestion should not receive new streams merely because it is next in a counter.

At minimum evaluate:

```text
active stream count
send backlog
recent write latency
health age
reconnect history
```

for new-stream placement.

## 12.3 Do not make one health probe a global kill switch

A brief local Xray/transient probe error should not automatically destroy every healthy carrier and every user stream.

Use hysteresis and separate “degraded” from “hard down”.

## 12.4 Do not rely only on ICMP

A server may ping while TCP 443 or the application path is filtered/broken.

Health should be end-to-end.

## 12.5 Do not change DNS before the spare path is verified

Spare should be READY first, then Cloudflare DNS updated.

## 12.6 Do not auto-failback on one healthy sample

Prevent flapping with a long recovery threshold and/or manual Telegram approval.

## 12.7 Do not bind two services to the same IP:443

Two independent listeners cannot both own the same exact `IP:443` unless a front dispatcher is used.

The shared Foreign-Spare design avoids this using loopback IP separation:

```text
127.0.0.1:443
127.0.0.3:443
```

## 12.8 Do not confuse DNS hostname with transport-visible routing information

Pointing `maya1.example.com` vs `maya3.example.com` to the same IP does not automatically tell a raw TCP listener which DNS name was originally queried.

The shared spare design works because only one profile is active at a time, not because the TCP server magically sees the DNS query.

---

# 13. THINGS THAT SHOULD NOT BE REPEATED WITHOUT A GOOD REASON

1. Blind Aegis server restart during peak traffic. One previous restart caused users not to reconnect cleanly and produced many closed-network stream errors.
2. Reintroducing the old direct backup installer `2be634...`.
3. Assuming UDP/Hysteria2 is acceptable for the user’s environment.
4. Declaring Aegis-T stable because the canary initially connected; real traffic later failed.
5. Increasing carrier count indefinitely as if it fixes the fundamental queue/HOL issue.
6. Treating global TCP cumulative counters as proof of a tunnel root cause without measuring deltas during the actual freeze.
7. Mixing IPs from different server pairs.
8. Installing/modifying 3x-ui as part of tunnel setup.
9. Using a moving GitHub raw `main` URL for production installer without pinning a commit.

---

# 14. CURRENT REPOSITORY OBSERVATION AT HANDOFF

At the time this history was created, the repository `main` root visibly contained documentation and tunnel-related directories including existing Aegis/DFR work. A direct code search for the string `frp` did not surface an obvious current FRP implementation in the connector search result.

Therefore the next assistant should **inspect the repository tree before assuming that “the FRP project” already exists as a complete implementation**.

The user’s phrase “FRP project” in the latest request should be treated as the requested next custom tunnel project unless a specific existing FRP path/branch is found during repo inspection.

Do not overwrite unrelated `dfr-shielded`, Aegis, or previous stable code without creating a deliberate new path/branch.

---

# 15. CURRENT OPEN QUESTIONS THAT MAY NEED USER INPUT DURING IMPLEMENTATION

Do not ask these all at once. The new interactive installer should ask what it needs. During design, only ask the user if the repo/server state cannot answer it.

Potential missing values:

- exact Iran/Foreign IPs for the new FRP deployment;
- exact domain/subdomain for the tunnel endpoint;
- whether the node is Normal Primary or Shared Spare;
- Maya profile target address (`127.0.0.1:443`, `127.0.0.3:443`, etc.);
- whether Cloudflare failover should be part of v1 or added after tunnel v1 is proven;
- Telegram bot token/chat ID (should be configured locally, not posted publicly);
- desired auto-failover threshold/policy;
- whether failback is manual or automatic after a stability window.

---

# 16. RECOMMENDED DEVELOPMENT SEQUENCE FOR THE NEXT CHAT

This is the safest sequence based on everything learned.

## Phase A — Repository / current implementation audit

1. Inspect full repo tree and existing DFR/Aegis code.
2. Identify any actual FRP code/path/branch.
3. Decide new isolated project directory and branch.
4. Document protocol architecture before code.

## Phase B — Transport correctness before DPI cosmetics

1. Implement reliable stream transport.
2. Implement bounded flow control/backpressure.
3. Implement fair scheduling/sharding.
4. Implement reconnection/draining behavior.
5. Implement health state machine with hysteresis.
6. Load test bursts and many logical streams.

Only after this should extra camouflage/DPI resistance be layered on.

## Phase C — DPI-resistance hardening

1. Avoid obvious plaintext magic/signatures.
2. Use valid TLS/HTTP behavior if wrapping in those protocols.
3. Use random but reasonable request paths/padding.
4. Add replay-safe authentication.
5. Add reconnect jitter.
6. Verify that camouflage does not create latency/freezes.

## Phase D — Installer / operations

1. interactive terminal installer for Iran/Foreign;
2. config validation;
3. systemd services;
4. health/status command;
5. diagnostics;
6. backup/rollback;
7. uninstall.

## Phase E — Panel

Build `FRP Tunnel - Ali Tavazoei Custom Version` dashboard on top of stable engine/CLI.

## Phase F — Shared spare / Cloudflare / Telegram

After core tunnel proves stable:

1. add Maya1/Maya3 spare profiles;
2. add selector;
3. add watchdog;
4. add Telegram UI;
5. add Cloudflare DNS automation;
6. test failure + recovery without user-facing surprises.

---

# 17. SHORT CONTINUATION PROMPT FOR A NEW CHAT

The user can paste exactly this into the new chat:

```text
اول برو داخل GitHub من، repo زیر رو باز کن:
aliiitavazoeiii-afk/backhaul-ha-installer

و این فایل رو کامل و دقیق بخون:
HISTORY-FRP-TUNNEL-ALI-TAVAZOEI-2026-08-29.md

این فایل history کامل پروژه و تمام تست‌ها و محدودیت‌های production ماست. بعد از خوندنش هیچ topology یا چیزی رو از خودت حدس نزن و چیزی که قبلاً fail شده رو دوباره پیشنهاد نده.

بعد پروژه جدید FRP Tunnel - Ali Tavazoei Custom Version رو از Section 11 همون فایل ادامه بده: اول repo و کدهای فعلی رو audit کن، ضعف‌های معماری رو جمع‌بندی کن، بعد نسخه نهایی پایدار و DPI-resistant و بدون freeze قابل اجتناب رو طراحی/پیاده‌سازی کن، installer تعاملی + health check + پنل مدیریت هم بساز.
```

---

# 18. FINAL STATE OF HANDOFF

Nothing in this history means the final custom FRP project has already been completed.

What **has** been completed/learned:

- multiple tunnel approaches were tested;
- Aegis 0.2.0 source behavior was inspected;
- real freeze windows were captured;
- carrier-count hypothesis was tested beyond 4 carriers;
- per-stream queue / HOL / scheduling weaknesses were identified;
- shared Maya1/Maya3 spare architecture was defined;
- Telegram + Cloudflare failover logic was designed conceptually;
- operational constraints and deployment safety rules are known.

What is **next**:

> Build the new, isolated, production-oriented **FRP Tunnel - Ali Tavazoei Custom Version**, using the lessons above rather than repeating Aegis’s queue/scheduling failure modes, then add the terminal installer, health/status UI, management panel, shared-spare selector, and later Cloudflare/Telegram failover automation.

**END OF HANDOFF**
