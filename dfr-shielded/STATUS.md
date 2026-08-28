# Status

This directory currently contains the integration scaffold and system-level contract only. The data-plane carrier must not be considered production-ready until strongSwan/XFRM endpoint handling is validated against Dragon Fruit Relay v2.1.0.

Required validation gates:
1. IKE establishment through carrier.
2. XFRM child SA outer-address correctness.
3. Bidirectional sustained traffic.
4. MTU/fragmentation under video workloads.
5. Reconnect without stale XFRM policy.
6. Native fallback remains functional.
