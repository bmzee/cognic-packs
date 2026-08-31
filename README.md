# cognic-packs

Capability packs for the Cognic governed-agent platform.

Each pack is a closed-manifest bundle (`pack.yaml` + agents + skills +
evals) admitted into a Cognic deployment through a governed lifecycle:
`validate → install (quarantined) → evals → activate`, with per-capability
kill switches, durable admin vetoes, and full audit attribution. Packs
declare every tool, facility, and egress they use; anything undeclared is
structurally unavailable to them.

## Packs

| Pack | Source | What it does |
|---|---|---|
| `gl-reconciler` | Anthropic FSI (Apache-2.0), converted | General-ledger reconciliation workflows |
| `kyc-screener` | Anthropic FSI (Apache-2.0), converted | KYC screening and escalation drafting |
| `statement-auditor` | Anthropic FSI (Apache-2.0), converted | Financial-statement audit assistance |
| `month-end-closer` | Anthropic FSI (Apache-2.0), converted | Month-end close checklists and workpapers |

Each pack directory carries its `import-report.json` documenting what
mapped cleanly, what required adaptation, and what is unmappable by
design (recorded, never silently dropped).

## Provenance and license

Converted from [anthropics/financial-services](https://github.com/anthropics/financial-services)
(Apache License 2.0) — see `LICENSE` and `NOTICE`. Instructional content is
preserved; conversions are format-level. Packs are admitted to a deployment
only after passing the platform's admission contract (signature, manifest
validation, green evaluations) — this repository is source, not a trusted
distribution channel.
