# Design Decisions

- Preserve upstream DFR management plane and registry.
- Preserve standard IKEv2/IPsec cryptography.
- Never rely on custom cryptography for confidentiality/integrity.
- Avoid a single TCP tunnel for all user traffic because head-of-line blocking can amplify video freezes.
- Treat camouflage/transport as replaceable and separately testable.
- Keep native DFR mode as a fallback until shielded mode passes sustained traffic and reconnect tests.
