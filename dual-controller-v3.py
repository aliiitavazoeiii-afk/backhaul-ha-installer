#!/usr/bin/env python3
import importlib.util
import subprocess
import sys
from pathlib import Path

V2 = Path('/opt/xhttp-dual/controller-v2.py')
if not V2.exists():
    raise SystemExit(f'Missing controller-v2: {V2}')

spec = importlib.util.spec_from_file_location('xhttp_dual_v2', str(V2))
v2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v2)
mod = v2.mod


def latency_health_check(node_cfg):
    """End-to-end tunnel health with latency quarantine.

    A filtered/degraded path can still return HTTP 204, but only after several
    seconds. Treat that as unhealthy so sticky users fail over instead of
    remaining pinned to an unusably slow foreign node.
    """
    host = node_cfg['socks_host']
    port = str(node_cfg['socks_port'])
    url = node_cfg.get('health_url') or 'https://cp.cloudflare.com/generate_204'
    timeout = int(node_cfg.get('health_timeout', 8))
    max_latency_ms = int(node_cfg.get('max_latency_ms', 1500))

    cmd = [
        'curl', '-sS', '-o', '/dev/null',
        '-w', '%{http_code} %{time_total}',
        '--max-time', str(timeout),
        '--connect-timeout', str(max(2, min(4, timeout // 2))),
        '--socks5-hostname', f'{host}:{port}',
        url,
    ]
    try:
        p = subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout + 3,
        )
        parts = p.stdout.strip().split()
        code = parts[0] if parts else '-'
        try:
            total_s = float(parts[1]) if len(parts) > 1 else 999.0
        except Exception:
            total_s = 999.0
        latency_ms = int(round(total_s * 1000))
        http_ok = p.returncode == 0 and code in {'200', '204'}
        latency_ok = latency_ms <= max_latency_ms
        ok = http_ok and latency_ok
        reason = 'ok' if ok else ('slow' if http_ok and not latency_ok else 'failed')
        return ok, f'http={code} rc={p.returncode} latency_ms={latency_ms} limit_ms={max_latency_ms} reason={reason}'
    except Exception as exc:
        return False, f'exception={exc} reason=failed'


mod.health_check = latency_health_check


if __name__ == '__main__':
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == 'diagnose':
            v2.diagnose()
        else:
            mod.main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
