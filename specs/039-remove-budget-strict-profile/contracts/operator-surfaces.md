# Contract: Operator surfaces (039)

Supersedes `specs/030-permissive-containment/contracts/operator-surfaces.md`
(profile rendering) and the budget-gauge parts of the console topbar contract.
The 030 "strict output byte-identical" guarantee is retired: the single output
below is the new baseline (FR-011, spec US2 scenario 2). Decisions: research R11.

| Surface | Removed | Kept / new |
|---|---|---|
| Console topbar (every view) | `<.cost_gauge>` (committed/reserved/budget), "breaker armed/tripped" chip, `.containment-chip` | run state chip, subject, **run spend** as one mono USD figure (`Ledger.snapshot().committed`) |
| Mission Control | budget/breaker state from `ConsoleReadModel.merge/3` ledger arg | per-feature spend, totals (from read model) |
| Configuration | budget fieldset + slider; Containment fieldset; agent-root `:pack_outdated` warning | other fieldsets; agent-root row `hidden`/`available` |
| Trigger | Budget row; containment profile select + note; `set_containment_profile` event | container notice line when not containerized (contracts/run-start.md §4) |
| Run Detail | Containment block | spend; historic `:breaker` clarify outcome still labelled; legacy settings keys hidden |
| Runs list / feature drawer | — | spend unchanged |
| `Report.format_status/1` (`print_status/0`) | `[BREAKER TRIPPED]`, containment line | spend line |
| Final report (Coordinator drain) | `breaker_tripped` key | `done/escalated/halted/failed/not_started/stopped_by/spend` |
| `Report.format_reason/1` | — | historic renderers kept: `{:needs_human, :breaker}`, `{:untrusted_workspace, …}`; new: `{:retired_option, :budget_usd \| :containment_profile}` with the why-text |
| PR body | containment note | everything else unchanged (incl. `Remediation.pr_note/1`) |

Rules:
- No surface shows "budget", "headroom", "reserved", "breaker", "strict" or
  "permissive" for a run started after this change (SC-002/SC-003).
- A run record from before this change renders without error; legacy
  `budget_usd`/`containment_profile` settings are not shown (SC-004).
- CSS: rules for the gauge, `.breaker-chip`, `.containment-chip` are deleted;
  no token value changes; `design_contract_test.exs` stays green.
- `docs/design-constitution.md` §185: "state chip, subject, and run spend
  persist in the topbar on every view" (no gauge/limit/breaker).
