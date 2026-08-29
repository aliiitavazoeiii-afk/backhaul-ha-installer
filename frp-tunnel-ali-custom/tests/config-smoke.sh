#!/usr/bin/env bash
set -Eeuo pipefail

FRP_VERSION="${FRP_VERSION:-0.71.0}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

case "$(uname -m)" in
  x86_64|amd64) arch=amd64; expected="84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716" ;;
  aarch64|arm64) arch=arm64; expected="f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266" ;;
  *) echo "unsupported CI arch"; exit 1 ;;
esac

pkg="frp_${FRP_VERSION}_linux_${arch}.tar.gz"
curl -fsSL --retry 4 "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}" -o "$tmp/$pkg"
echo "$expected  $tmp/$pkg" | sha256sum -c -
tar -xzf "$tmp/$pkg" -C "$tmp"
d="$tmp/frp_${FRP_VERSION}_linux_${arch}"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=tunnel.example.com" \
  -addext "subjectAltName=DNS:tunnel.example.com" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
printf '%064d\n' 0 >"$tmp/token"

cat >"$tmp/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = 18443
proxyBindAddr = "127.0.0.1"
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$tmp/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tcpMux = false
transport.tcpKeepalive = 30
transport.maxPoolCount = 64
transport.heartbeatTimeout = 90
transport.tls.force = true
transport.tls.certFile = "$tmp/cert.pem"
transport.tls.keyFile = "$tmp/key.pem"
allowPorts = [{ single = 19443 }]
maxPortsPerClient = 1
userConnTimeout = 10
detailedErrorsToClient = false
webServer.addr = "127.0.0.1"
webServer.port = 17500
webServer.user = "ali"
webServer.password = "test-pass"
log.to = "console"
log.level = "info"
EOF

cat >"$tmp/frpc.toml" <<EOF
clientID = "ali-ci"
serverAddr = "tunnel.example.com"
serverPort = 18443
loginFailExit = false
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$tmp/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.protocol = "wss"
transport.tls.enable = true
transport.tls.serverName = "tunnel.example.com"
transport.tls.trustedCaFile = "$tmp/cert.pem"
transport.tls.disableCustomTLSFirstByte = true
transport.tcpMux = false
transport.poolCount = 24
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 30
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 90
transport.wireProtocol = "v1"
webServer.addr = "127.0.0.1"
webServer.port = 17400
webServer.user = "ali"
webServer.password = "test-pass"
log.to = "console"
log.level = "info"

[[proxies]]
name = "ali-vpn-ci"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = 19443
transport.useEncryption = false
transport.useCompression = false
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 5
EOF

"$d/frps" verify -c "$tmp/frps.toml"
"$d/frpc" verify -c "$tmp/frpc.toml"
echo "FRP v${FRP_VERSION} config schema smoke test: OK"
