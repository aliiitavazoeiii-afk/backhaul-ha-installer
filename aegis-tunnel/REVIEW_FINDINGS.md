# Pre-production review findings

The initial Aegis 0.1.0 canary code is not the final single-primary release. Review identified these items to fix before production deployment:

1. Local TCP listener existence is not sufficient primary health. Readiness must become false when all carriers are gone and when the Foreign Xray target is unhealthy.
2. A newly accepted local stream should retry another carrier when the initially selected carrier dies during OPEN.
3. Reconnect backoff needs jitter and should not reset after a very short-lived connection.
4. Cryptographic randomness failure must fail closed; timestamp fallback is not acceptable for path generation.
5. Carrier authentication comparison should be constant-time.
6. Integration tests need readiness loss/recovery, target loss/recovery, bad-token rejection, and carrier churn in addition to parallel stream transfer.
7. The final gateway must be primary/backup only; no round-robin between Foreign servers.
8. Failback must not forcibly terminate established backup sessions when primary recovers.
