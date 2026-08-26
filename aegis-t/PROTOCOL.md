# Aegis-T wire protocol 1.0

## 1. Carrier establishment

Foreign opens a TCP connection to Iran public `:443`, performs TLS with the configured carrier domain as SNI, and sends an HTTP/1.1 `POST` to:

```text
<path_prefix>/<24 hex chars>
```

Authentication headers:

```text
X-Request-Time: <unix seconds>
X-Request-ID: <32 hex chars>
X-Request-Signature: HMAC-SHA256(token, time + "\n" + nonce + "\n" + path)
```

The server accepts timestamps within 75 seconds and rejects nonce replay. `X-Client-Data` contains random variable-length padding. All of these headers are inside TLS.

Valid carriers receive `HTTP/1.1 200 OK` and become idle warm carriers. Invalid requests receive a normal HTTP 404 and are never upgraded to the carrier state.

## 2. Assignment

When Iran accepts a user TCP connection, it removes one idle carrier and sends one encrypted control byte:

```text
0x51 = OPEN
```

Foreign dials its configured local target, normally `127.0.0.1:443`.

It replies:

```text
0x52 = READY
0x53 = TARGET_FAILED
```

If READY is received, all deadlines are cleared and the connection switches permanently to raw full-duplex payload mode.

## 3. Payload

There is no Aegis framing after READY. No stream IDs, multiplexing, record queue, or application-level chunking exists. Both ends use backpressured byte copying until either TCP side closes.

## 4. Carrier lifecycle

A carrier can be used for exactly one user connection and is then closed. Foreign replenishes the warm pool immediately after a carrier is assigned. Idle carriers expire and are replaced periodically to prevent stale half-open sessions from accumulating.

## 5. Readiness

Iran exposes a TCP readiness listener only while at least `min_ready` authenticated idle carriers exist. HAProxy sends new user sessions to Aegis-T only while that listener is up.
