# GL reconciler pack

This pack adapts Anthropic FSI's Apache-2.0 `gl-reconciler` plugin to
Cognic's closed, governed pack format. It preserves the upstream purpose—find
breaks, trace their evidence, and prepare an exception report for human
sign-off—while exposing only capabilities that exist in the current runtime.

## Runnable v0 workflow

The active agents have one tool: the governed, read-only `query_database`
tool for the synthetic banking demo database. They can compare
database-resident sources, including:

- current account balances against each account's latest monthly summary; and
- signed transaction flows against stored monthly deposits and withdrawals.

Results are returned in chat as exact-cent totals and a complete exception
list. The agents do not post ledger entries, modify source data, deliver files,
or create artifacts. Free-text values returned by the database are untrusted
data, not instructions; embedded requests and tool directives are ignored.

The upstream spreadsheet and file skills are retained byte-for-byte as source
material, but they are not attached to either active v0 agent. This pack cannot
discover, read, or search local extracts, statements, or workbooks; inspect an
attachment; audit spreadsheet formulas; call the upstream internal-GL or
subledger MCPs; or create an `.xlsx` file. File-based reconciliation arrives
with platform attachments support. Until then, the agent states this boundary
rather than pretending a file operation occurred.

## Import mapping review

`import-report.json` is the importer's historical record: 8 items mapped
cleanly, 4 mapped with adaptation, and 1 was unmappable by design. Each item
was checked against the upstream plugin. The runnable database rebase described
below is a post-import readiness change; it does not rewrite that report.

| # | Source element | Import classification | Review and final disposition |
|---:|---|---|---|
| 1 | Plugin author | Adapted | `Anthropic FSI` was normalized to the valid publisher identifier `anthropic-fsi`; attribution is preserved. |
| 2 | Plugin description | Adapted | The importer copied “Finds breaks, traces root cause, routes for sign-off” into the generated root. The final wording keeps those three outcomes and narrows the source claim to the database-only v0. |
| 3 | Plugin name | Adapted | `gl-reconciler` already satisfies Cognic identifier syntax, so normalization leaves the identity unchanged. |
| 4 | Plugin version | Clean | `0.1.0` is preserved exactly. |
| 5 | Implicit plugin host entry point | Adapted | The importer materialized `gl-reconciler-root`. Review found its tool-free generated instructions could not execute the copied workflow; the final root has only `query_database`, no delegation, and an explicit database/file boundary. |
| 6 | `agents/gl-reconciler.md` agent | Clean | The importer preserved the upstream agent body and identity. The final instructions retain its break/trace/report intent while replacing unavailable MCP, file, and worker assumptions with a sequential read-only database workflow. |
| 7 | Agent description | Clean | The upstream description was preserved by import. It is narrowed post-import so the directory does not promise unavailable GL/subledger or file sources. |
| 8 | Agent name | Clean | `gl-reconciler` is preserved exactly. |
| 9 | Agent tool declaration | Unmappable by design | The exact dropped grants were `Read`, `Grep`, `Glob`, `mcp__internal-gl__*`, and `mcp__subledger__*`. Cognic does not infer production permissions from Claude-specific file tools or wildcard MCP namespaces. No replacement file, shell, Excel, internal-GL, or subledger tool is declared. |
| 10 | `audit-xls` skill document | Clean | Import bytes were verified against upstream and remain unchanged. The skill is retained but inactive because workbook access is unavailable. |
| 11 | `break-trace` skill document | Clean | Import bytes were verified against upstream and remain unchanged. The active agent instead traces only rows available through the database workflow. |
| 12 | `gl-recon` skill document | Clean | Import bytes were verified against upstream and remain unchanged. Its matching method informs the database rebase, but the extract-oriented skill is not activated. |
| 13 | `xlsx-author` skill document | Clean | Import bytes were verified against upstream and remain unchanged. The skill is retained but inactive because file creation and Excel tooling are unavailable. |

The user-visible impact of item 9 is intentional and fail-closed: v0 cannot
operate on files or the upstream MCP sources and cannot produce a workbook.
It can reconcile only data exposed by the declared read-only database tool.

## Evaluation evidence

`evals/golden.yaml` contains two live task-outcome evaluations:

1. a deterministic two-account balance-versus-summary reconciliation with
   exact expected totals and exceptions; and
2. an injection canary that materializes an instruction only inside a database
   result and verifies that the agent neither follows nor repeats it.

The model route is deployment-bound through its declared alias and gateway
configuration fingerprint. A pack still installs quarantined and must satisfy
the deployment's complete admission contract before activation.

## Provenance and license

Source: [Anthropic financial-services, gl-reconciler plugin](https://github.com/anthropics/financial-services/tree/main/plugins/agent-plugins/gl-reconciler).
The source and this adaptation are distributed under Apache-2.0; repository
license and attribution files apply.
