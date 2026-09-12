#!/usr/bin/env python3
import copy
import importlib.util
import random
import socket
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

V3 = Path('/opt/xhttp-dual/controller-v3.py')
if not V3.exists():
    raise SystemExit(f'Missing controller-v3: {V3}')

spec = importlib.util.spec_from_file_location('xhttp_dual_v3', str(V3))
v3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v3)
mod = v3.mod
_rng = random.SystemRandom()
_next_probe = {'f1': 0.0, 'f2': 0.0}
_scheduler_initialized = False


def _health_urls(node_cfg):
    urls = node_cfg.get('health_urls')
    if isinstance(urls, list):
        urls = [str(x).strip() for x in urls if str(x).strip()]
    else:
        urls = []
    if not urls:
        urls = [str(node_cfg.get('health_url') or 'https://cp.cloudflare.com/generate_204').strip()]
    return urls


def latency_probe_v4(node_cfg):
    """Probe randomized HTTPS targets; try another target before declaring the tunnel bad."""
    urls = list(_health_urls(node_cfg))
    _rng.shuffle(urls)
    attempts = []
    final = None
    for idx, url in enumerate(urls[:2]):
        cfg = copy.deepcopy(node_cfg)
        cfg['health_url'] = url
        ok, detail, reason = v3.latency_probe(cfg)
        try:
            host = urlparse(url).hostname or '-'
        except Exception:
            host = '-'
        attempts.append(f'{host}:{reason}')
        final = (ok, f'target={host} {detail}', reason)
        if ok:
            if idx:
                return True, f'fallback_after={",".join(attempts[:-1])} {final[1]}', 'ok'
            return final
    if final is None:
        return False, 'reason=failed no_health_target', 'failed'
    return final[0], f'attempts={",".join(attempts)} {final[1]}', final[2]


def _init_scheduler(cfg):
    global _scheduler_initialized
    if _scheduler_initialized:
        return
    now = time.monotonic()
    nodes = ['f1', 'f2']
    _rng.shuffle(nodes)
    _next_probe[nodes[0]] = now + _rng.uniform(0.2, 2.5)
    _next_probe[nodes[1]] = now + _rng.uniform(3.0, 8.0)
    _scheduler_initialized = True


def _schedule_next(node, cfg, healthy):
    base = float(cfg.get('healthy_probe_interval', cfg.get('check_interval', 18)))
    if healthy is False:
        base = float(cfg.get('unhealthy_probe_interval', max(8.0, min(base, 12.0))))
    lo = float(cfg.get('probe_jitter_min', 0.55))
    hi = float(cfg.get('probe_jitter_max', 1.75))
    lo = min(max(lo, 0.25), 1.0)
    hi = min(max(hi, 1.0), 3.0)
    if hi < lo:
        lo, hi = hi, lo
    delay = max(3.0, base * _rng.uniform(lo, hi))
    _next_probe[node] = time.monotonic() + delay
    return delay


def update_health_v4(state, cfg):
    """v3 health semantics with independent randomized per-node scheduling."""
    _init_scheduler(cfg)
    now = time.monotonic()
    due = [n for n in ('f1', 'f2') if now >= _next_probe[n]]
    if not due:
        return False

    changed = False
    hard_fth = int(cfg.get('failure_threshold', 3))
    slow_fth = int(cfg.get('slow_failure_threshold', 2))
    rth = int(cfg.get('recovery_threshold', 5))
    _rng.shuffle(due)

    for node in due:
        nstate = state['nodes'][node]
        ok, detail, reason = latency_probe_v4(cfg['nodes'][node])
        nstate['last_check'] = mod.dt.datetime.now().isoformat(timespec='seconds')
        nstate['last_detail'] = detail
        nstate['last_reason'] = reason
        m = v3.re.search(r'latency_ms=(\d+)', detail)
        nstate['last_latency_ms'] = int(m.group(1)) if m else None

        old = nstate.get('healthy')
        if ok:
            nstate['failures'] = 0
            nstate['slow_failures'] = 0
            nstate['successes'] = int(nstate.get('successes', 0)) + 1
            if old is None or (old is False and nstate['successes'] >= rth):
                nstate['healthy'] = True
        else:
            nstate['successes'] = 0
            nstate['failures'] = int(nstate.get('failures', 0)) + 1
            if reason == 'slow':
                nstate['slow_failures'] = int(nstate.get('slow_failures', 0)) + 1
                threshold = slow_fth
            else:
                nstate['slow_failures'] = 0
                threshold = hard_fth
            if old is not False and nstate['failures'] >= threshold:
                nstate['healthy'] = False

        if old != nstate.get('healthy'):
            nstate['last_change'] = mod.dt.datetime.now().isoformat(timespec='seconds')
            changed = True
            mod.log(f'{node} health {old} -> {nstate.get("healthy")} ({detail})')

        delay = _schedule_next(node, cfg, nstate.get('healthy'))
        nstate['next_probe_in_s'] = round(delay, 1)

    return changed


def daemon_v4():
    cfg = mod.load_json(mod.CONFIG_PATH)
    tick_min = max(3.0, float(cfg.get('controller_tick_min', 5.0)))
    tick_max = max(tick_min, float(cfg.get('controller_tick_max', 12.0)))
    mod.log(
        'controller-v4 started with independent randomized health scheduling '
        f'tick={tick_min:.1f}-{tick_max:.1f}s '
        f'healthy_probe={float(cfg.get("healthy_probe_interval", cfg.get("check_interval",18))):g}s '
        f'unhealthy_probe={float(cfg.get("unhealthy_probe_interval",10)):g}s'
    )
    while True:
        try:
            with mod.get_lock():
                mod.sync_once()
        except Exception as exc:
            mod.log(f'ERROR: {exc}')
            try:
                state = mod.load_state()
                state['last_error'] = str(exc)
                mod.save_state(state)
            except Exception:
                pass
        time.sleep(_rng.uniform(tick_min, tick_max))


def _tcp_probe(host, port, timeout=5.0):
    started = time.monotonic()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            ms = int(round((time.monotonic() - started) * 1000))
            return True, ms, 'ok'
    except Exception as exc:
        ms = int(round((time.monotonic() - started) * 1000))
        return False, ms, str(exc)


def netcheck():
    cfg = mod.load_json(mod.CONFIG_PATH)
    print('XHTTP DUAL NETWORK CHECK')
    for node in ('f1', 'f2'):
        nc = cfg['nodes'][node]
        host = str(nc.get('foreign_ip') or '-')
        port = int(nc.get('foreign_port', 443))
        tcp_ok, tcp_ms, tcp_detail = _tcp_probe(host, port)
        tun_ok, tun_detail, reason = latency_probe_v4(nc)
        print(
            f'{node.upper()}: foreign={host}:{port} '
            f'tcp={"ok" if tcp_ok else "failed"} tcp_ms={tcp_ms} '
            f'tunnel={"ok" if tun_ok else reason}'
        )
        print(f'    tcp_detail={tcp_detail}')
        print(f'    tunnel_detail={tun_detail}')


mod.health_check = lambda node_cfg: latency_probe_v4(node_cfg)[:2]
mod.update_health = update_health_v4
mod.daemon = daemon_v4


if __name__ == '__main__':
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == 'diagnose':
            v3.v2.diagnose()
        elif len(sys.argv) >= 2 and sys.argv[1] == 'netcheck':
            netcheck()
        else:
            mod.main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
