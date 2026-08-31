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

## Building your own pack

A Cognic pack is a directory with a closed-schema `pack.yaml` at its root:

```yaml
schema_version: 1
facility_api_version: 1.0.0
name: my-pack
version: 1.0.0
publisher: your-org
license: Apache-2.0
risk_tier: baseline          # baseline | enhanced | vigilant
agents:
  - id: my-agent
    name: My Agent
    description: One honest sentence about what this agent is for.
    source: { path: agents/my-agent/agent.md }
    model_tier: cloud        # routed by the deployment admin
    declared_tools: [my_tool]   # the grant — undeclared tools do not exist
    skills: [my-skill]
    approval_profile: on_request
skills:
  - id: my-skill
    source: { path: agents/my-agent/skills/my-skill/SKILL.md }
    license: Apache-2.0
tools:
  - name: my_tool
    description: What it does, in the user's language.
    input_schema: { type: object, properties: {}, additionalProperties: false }
    effect: read_only        # read_only | governed_write (write ⇒ human approval)
    data_classes: [myData]
    gating: auto             # auto | human_approval
facilities: [model_tiers]    # consume platform facilities; never embed your own
egress: []                   # empty = the pack can reach nothing external
evals:
  suite: { path: evals/golden.yaml }
  runner: cognic_gateway
  grader: task_outcome
```

Ground rules the platform enforces (not conventions — refusals):

- **Everything is declared.** Unknown manifest fields are parse errors; an
  undeclared tool, facility, or egress host does not exist for the pack.
- **Facility-first.** If the platform provides a capability (memory,
  artifacts, storage, scheduling, approvals, model routing), packs must
  consume it — a pack embedding its own store, scheduler, or mailer is
  rejected at admission.
- **Writes are governed.** `governed_write` tools require the approvals
  facility, and every outbound send waits for an explicit human decision.
- **Lifecycle:** `cognic pack validate` → `install` (always quarantined) →
  `evals` → `activate` — activation is refused until signature, manifest,
  and evaluation evidence are all green. Any capability can be durably
  vetoed by an admin afterward.
- **Descriptions are load-bearing.** Agent and tool descriptions surface
  directly to end users; thin descriptions fail admission review.

Existing Claude plugins and MCP server declarations convert with
`cognic pack import --from claude-plugin|openai-mcp` — the four packs in
this repository were produced exactly that way, and each
`import-report.json` shows what such a conversion looks like.
