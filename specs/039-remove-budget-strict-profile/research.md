# Research: Remove Cost Budget Breaker and Strict Containment Profile

**Feature**: 039-remove-budget-strict-profile | **Date**: 2026-10-09

Inputs: a full code sweep of the budget/breaker mechanism and of the
strict/permissive profile split (lib/, config/, priv/, scripts/, test/, docs/),
plus the four spec clarifications of 2026-10-09. Each decision below names the
alternative it rejected.

---

## R1 — What happens to `Autonomous.Ledger`

**Decision**: Shrink `Ledger` to an informational **cost accumulator**:
`record/3`, `spent/1`, `restore/2`, `snapshot/1` (returns `%{committed: float}`).
Delete `reserve/2`, `set_budget/2`, `breaker_tripped?/1`, `default_budget/0`,
`tripped?`/`reserved_total` and every budget field of its state. It keeps its
name and its place in the app tree (`application.ex:23`), and keeps feeding
`Coordinator.spend/1` → `report.spend` → `close_run(spend_usd: …)`.

**Rationale**: The sweep found production never calls `reserve/2` (only
`ledger_test.exs` does) — reservations are already dead code; the live inputs
are `record/3` (every `record_cost/2` in the four phase actions), `restore/2`
(resume) and `breaker_tripped?/1`. Removing only the gating half is the
smallest change that keeps every informational number exactly as it is today
(FR-003, SC-003). The `:ledger` seam threaded through Coordinator,
FeatureRunner, FeatureAgent and the actions stays, so the injected-seam tests
keep working with minimal churn.

**Alternatives considered**:
- *Delete the Ledger and derive run spend from store cost entries*
  (`Store.Query.effective_spend/1`, `Recovery.spend_of/1`). More correct
  per-run (the Ledger is app-lifetime and only restored on resume), but it
  changes what `report.spend` means — a behaviour change this feature does not
  ask for — and turns Coordinator/console unit tests that run without a store
  into store-dependent ones. Recorded as a possible follow-up, not done here.
- *Keep the Ledger whole and just never trip it (budget = ∞)*. Leaves dead
  breaker code and wording on every surface; violates FR-004/FR-005/FR-016.

## R2 — `Release.next/3` third argument

**Decision**: Keep the arity; rename the argument `breaker_tripped?` →
`blocked?`. `Coordinator.blocked?/1` becomes `store_unwritable?(state)` only.

**Rationale**: The argument is not breaker-only — `Coordinator.blocked?/1`
(coordinator.ex:201) ORs the breaker with the `Store.Health` persistence
breaker, which must keep stopping new releases when the store cannot be
written. Only the cost half goes.

**Alternatives**: drop the argument (`next/2`) — would also drop the
persistence drain, regressing feature 018 behaviour.

## R3 — Every breaker branch on the session-driving path

**Decision**: Delete the cost-breaker branch at every site and keep the
supersession-drain branch beside it, unchanged:
`FeatureRunner` (phase boundary halt, clarify tick/answered, `exit_for(:breaker)`),
`PhaseStep.retry_allowed?/1` (→ `not Workers.drain_requested?()`),
`SessionRetry.once/2` (drop `breaker?` key), `Chunking`/`ChunkRunner`
(Row 7 and `breaker?` signal), `Remediation.next/2` row 4, `AnalyzeRunner`
(`{:halted, :breaker}`), `InteractiveClarify.on_exit(:breaker)`.

**Rationale**: FR-001/FR-005 forbid any spend-caused halt; FR-019 keeps
`Workers.drain_requested?/0` working. Every site already checks the two
conditions side by side, so the deletion is local and the drain tests act as
the regression guard.

**Historic values kept readable**: the atom `:breaker` still appears in old
records (`{:needs_human, :breaker}` terminal reasons, clarify-round
`outcome: :breaker`). `Store.Records` decodes values untyped, so they load.
`Report.format_reason/1` and `RunDetailLive.clarify_outcome_label/1` keep their
`:breaker` clauses as historical renderers; `Writer.close_clarify_round` keeps
`:breaker` in its accepted-outcome guard for old rows but nothing new writes
it (FR-017, SC-004).

## R4 — Refusing the removed options (Clarification Q4)

**Decision**: Reuse feature 019's retired-setting mechanism on every surface.

| Surface | Change |
|---|---|
| Start/continue options | `@retired_opts` (`lib/autonomous.ex:193`) gains `:budget_usd`, `:containment_profile` → `{:error, {:preflight, [{:retired_option, key}]}}`, first step of `run/1`, `run_spec/2`, `resume/2`, `resume_run/1`, `continue_run/1` (all already call `reject_retired_opts/1`) |
| App env | `@retired_app_env` (`application.ex:72`) gains `:budget_usd`, `:containment_profile`; boot raises naming the key |
| Environment | `config/runtime.exs`: `AUTONOMOUS_BUDGET_USD` and `AUTONOMOUS_CONTAINMENT_PROFILE` join the retired `raise` block (set at all → boot aborts naming it); the `budget_usd` mapping is deleted |
| Live config | `LiveConfig.validate_field/2` returns a retired-field error naming `budget_usd` (not the generic "unknown field") |
| Console | No budget/profile field exists to submit (Trigger, Configuration) |

The error renderer (`Report.format_reason`/preflight rendering) gains a
039-specific hint per key (cost is informational; one containment behaviour,
run in the container).

**Rationale**: Constitution II "Retired settings" mandates exactly this
(refuse on every surface, never accept-and-ignore). The mechanism exists,
is tested, and produces a reason naming the key (SC-005).

**Alternatives**: silently ignore unknown keys (current behaviour for keys not
in the list) — rejected by the clarification and by Principle II.

## R5 — The scope-guard hook: delete it

**Decision**: Delete `priv/target_pack/.claude/hooks/scope_guard.py`, the
`hooks.PreToolUse` registration in the pack's `settings.json`, and
`test/autonomous/scope_guard_test.exs`. Pack `settings.json` keeps `env`
(032 shell timeouts), `permissions.defaultMode` and the `allow` list, and
still carries no `permissions.deny`.

**Rationale**: After `strict` goes, the hook's whole decision is
"orchestrated → allow, interactive → allow". What remains is only
"unparseable stdin → deny" and "undecided origin → strict deny", which hits
humans using IDE/SDK entrypoints — never wanted (FR-013: a human's own session
is never denied). The sudo grammar (FR-015) only ever ran under `strict`.
A hook that allows everything is dead code that still forks `python3` on every
tool call. `TargetPack.merge_settings/2` lets the pack win every key but `env`,
so a re-install drops the stale `hooks` registration from a target's
`settings.json`.

**Alternatives**: keep an allow-all stub hook at contract 6 — dead code with a
per-call `python3` fork and a red-team test suite guarding nothing.

## R6 — Pack contract 6 and the always-on pack check (Clarification Q3)

**Decision**: The pack contract moves from the hook (`PACK_CONTRACT = 5` in
`scope_guard.py`) to a dedicated marker, `priv/target_pack/.claude/autonomous-pack.json`
(`{"contract": 6}`), installed by `TargetPack.install/2`. `TargetPack.verify/2`
loses its `:profile` option and runs `check_pack_contract/1` on **every** run,
reading the *committed* tree (`git show HEAD:…`, as today):

1. `.claude/autonomous-pack.json` committed with `contract >= 6`;
2. committed `.claude/settings.json` registers no `scope_guard.py` hook and has
   no `permissions.deny`;
3. no committed `.claude/hooks/scope_guard.py`.

Any failure → `{:pack_outdated, path, hint}`, the hint naming contract 6 and the
fix (`TargetPack.install/2` into the target, commit, re-run). `install/2` also
deletes a stale `.claude/hooks/scope_guard.py` in the target.
`@permissive_min_contract`, `@agent_root_min_contract`, `contract_of/1`
(python probe), `parse_contract/1`, `agent_root_warning/1` and the
`:pack_below_agent_root_contract` warning are deleted.

**Rationale**: Clarification Q3 (bump contract; fail older packs with reinstall
instructions). It also closes the one real migration hazard the sweep found:
a target still carrying a committed contract-2..5 hook would resolve a session
without the `AUTONOMOUS_ORCHESTRATED`/`AUTONOMOUS_CONTAINMENT_PROFILE` markers
as "undecided → strict" and deny writes. Because worktrees come from the
committed tree, refusing an old committed pack at preflight means no session
can ever meet an old hook — so the orchestrator can stop emitting those two
markers. A JSON marker is read with `Jason`, no python3 probe.

**Alternatives**:
- *Keep emitting the old markers for a transition release* — unnecessary once
  preflight refuses old packs; leaves profile vocabulary on the launch env.
- *Version key inside `settings.json`* — Claude Code owns that file's schema;
  an unknown top-level key risks a CLI settings-validation warning.

## R7 — Per-phase permissions and session env

**Decision**: `PhaseRequest` drops the `:containment` option,
`strict_permissions/1` and the per-phase table. Every phase, remediation and
describe session gets what `permissive` granted: `permission_mode:
:bypass_permissions`, the full tool set (`@allowed_tools`, renamed from
`@permissive_allowed_tools`), and the headless exclusions
`~w(Agent Task ScheduleWakeup Monitor)` unchanged. `session_metadata/…` no
longer merges `Containment.session_env/1`. `AgentRoot.session_env/1` markers
and `AgentRoot.prompt_note/1` stay (FR-015). `Autonomous.Containment` is
deleted.

**Rationale**: FR-007/FR-009. The headless exclusions are not containment
(constitution 6.0.1 already says so) and stay.

## R8 — Untrusted-workspace gate (feature 036)

**Decision**: `WorkspaceTrust.settle/…` loses the profile argument and always
warns (the `permissive` branch). The `:untrusted_workspace` failure gate in
`Pipeline`, `Chunking` Row U and `FeatureRunner.remediation_failure_reason/…`
is deleted (now unreachable). Detection (`observe`/`parse_line`/`Collector`,
`result.untrusted_workspace`) and the entrypoint `trust_workspaces` step stay.
`Report.format_reason({:untrusted_workspace, …})` stays as a historical
renderer.

**Rationale**: That gate fired only under `strict`. Keeping it alive would
re-create a strict-only failure path the single profile does not have.

**Alternative**: promote the warning to a hard failure for everyone — a new
behaviour no one asked for; out of scope.

## R9 — Non-container start warning (Clarification Q1, FR-014)

**Decision**: A pure `RuntimeNotice.container_warning(containerized?)` returns
`nil | String.t()`. The run-start preflight (`run/1`, `run_spec/2`, resume,
continue) calls it with `ContainerGuard.containerized?/0` and, when non-nil,
emits `Logger.warning/1` (loud, multi-line, naming `scripts/autonomous` and
that sessions run with full access and no in-tree deny list) and proceeds.
The console Trigger start-confirm (`StartConfirm`) shows the same text as a
warning line when not containerized.

**Rationale**: `ContainerGuard.check!/0` already refuses a boot outside the
image whenever `require_container` is true; so this warning only fires where
that guard was deliberately disabled (host development, test). That is exactly
the case the operator should be told about, and never a block.

**Alternative**: block — rejected by the clarification.

## R10 — Store and stored records

**Decision**: No schema migration; store stays at v7. No table has a budget,
breaker or profile column — those values only live inside
`speckit_run_settings.settings` (the `RunContext.to_map/1` map) and
`speckit_settings_amendment.changes`. `RunContext` drops the `budget_usd` and
`containment_profile` fields; `from_map/1` already reads keys one by one and
ignores unknown ones. `RunSettingsView` hides the legacy keys
(`@dropped ~w(budget_usd containment_profile)`) so old runs render without a
stale row. Resume/continue never read, compare or write a profile
(`guard_containment_profile/2` deleted) — FR-010.

**Rationale**: FR-017/SC-004 need read-tolerance, which the decoder already
gives (values are untyped terms). A clean-break or refusal migration would
violate "legacy records remain readable".

## R11 — Operator surfaces

**Decision**:
- Topbar: delete `<.cost_gauge>` (`core_components.ex:244-302`) and the
  breaker chip; show run spend as a plain mono figure (`Ledger.snapshot().committed`
  formatted as USD). Delete the containment chip. CSS: delete gauge,
  `.breaker-chip`, `.containment-chip` rules — tokens untouched.
- `Report.format_status/1`: delete `[BREAKER TRIPPED]` and the containment
  line; keep the spend line. Final report drops `breaker_tripped`.
- Coordinator `status/1`/`build_report`: drop `breaker_tripped` and
  `containment_profile` keys.
- Config page: delete the budget fieldset/slider and the Containment fieldset;
  agent-root row states only `:hidden | :available` (`AgentRootView`).
- Trigger: delete the Budget row and the profile select.
- Run Detail: delete the Containment block.
- PR body: no containment note.
- Console read model: `ConsoleReadModel.merge/3` → `merge/2` without the ledger
  snapshot; `ConsoleProjection` and `CoordinatorProbe.ledger/2` drop the ledger
  probe (per-feature `spend` in the read model stays). Topbar spend reads the
  Ledger snapshot directly (it is a local, never-blocking call).
- Runtime-health dot (`layouts.ex:69`) keeps `Process.whereis(Ledger)` — the
  Ledger still exists (R1).

**Rationale**: FR-004/FR-011/SC-003, and constitution VII must be amended so
it no longer *requires* a gauge (R12). The design-contract guard
(`design_contract_test.exs`) must stay green — deleting rules adds no literal.

## R12 — Constitution 7.0.0 (FR-018)

**Decision**: MAJOR bump 6.1.0 → 7.0.0, amended in this feature's change (per
project rule: semantic changes flow through a spec). Principle numbering kept
(other specs cite III/IV/V by number).

- **III. Container-Bounded Execution** (was Least-Privilege Containment):
  one behaviour for orchestrator sessions — full tool set per phase,
  `bypass_permissions`, headless exclusions only; the container is the
  supported runtime and outer boundary; a non-container start warns loudly and
  proceeds; the committed pack MUST meet the current contract (preflight fails
  loud otherwise); a human's interactive session is never denied; correctness
  gates and session deadlines are not containment.
- **IV. Cost Transparency; Drain, Don't Kill** (was Cost-Bounded Autonomy):
  cost MUST be measured per phase attempt (actual preferred, estimate
  fallback) and rolled up, MUST be shown, and MUST NOT gate any work.
  Drain-don't-kill is kept for supersession and persistence draining.
- **V**: drop "a tripped cost breaker" from the interactive-clarify exit list
  and "subject to the cost breaker" from the remediation loop.
- **VII**: global run state = run state, subject, run spend; drop the gauge
  committed/reserved rule and breaker status.
- **I / Tech Stack / Quality**: `Ledger` described as the cost accumulator;
  breaker test bullet → "release and drain logic"; hook red-team bullet deleted.
- `docs/design-constitution.md` §185 updated in the same change.

**Rationale**: Removes two MUST-level guarantees (cost breaker, strict
default) — backward-incompatible governance change → MAJOR, same class as
6.0.0.

## R13 — Docs, scripts, smoke checks (FR-016, SC-007)

**Decision**:
- Rewrite: `docs/enforcement.md` (container + per-phase + pack contract 6),
  `docs/runbook.md` ("Cost breaker" section → "Cost reporting"; profile
  sections removed), `docs/container.md`, `docs/workflow.md` (mermaid LED/BRK
  nodes), `docs/harness-contract.md` (touch), `README.md`, `CLAUDE.md`.
- `priv/prompts/agent_root.md:6`: grammar no longer enforced → guidance only
  ("never remove/purge/upgrade").
- Scripts: delete the "budget per instance" warnings
  (`scripts/autonomous:239`, `container-entrypoint.sh:311-312`); fix strict
  wording in `scripts/autonomous --agent-root` help, entrypoint `say`/comments,
  `Dockerfile` sudoers comment.
- `scripts/container-smoke.sh`: delete the strict-hook checks in `us1`
  (150-162) and `us5` (531-535), and the whole `us-trust-hook` subcommand;
  keep `trust`, `sysdeps`, everything else.
- Leave historical: `docs/autonomous-implementation-plan.md`,
  `docs/phase7-ledgerlite-runbook.md`, `docs/control-plane-design-reference/`,
  `specs/0NN-*` for earlier features.

## R14 — Test strategy (FR-020)

- **Delete**: `scope_guard_test.exs`, `containment_test.exs`, breaker cases
  (coordinator, release, chunking row 7, remediation row 4, analyze_runner,
  feature_runner(+clarify wait), chunk_runner, phase_step, session_retry,
  run_spec, resume_run, ledgerlite_dryrun breaker drill, live_config budget,
  console budget/gauge/breaker cases), `untrusted_gate_test` strict half.
- **Rewrite**: `ledger_test.exs` (accumulator only), `phase_request_test.exs`
  (every phase = full set), `target_pack_test.exs` (contract 6 always-on
  check, stale-hook removal), `continue_run_atomic_test.exs:278-340`
  (pack-lag incident → always-on check), `untrusted_gate_test` (warn-only),
  `agent_root_*` tests (no `scope_guard[` denial filter).
- **Add**: retired-option refusal for both keys on every entry point
  (`run/1`, `run_spec/2`, `resume/2`, `resume_run/1`, `continue_run/1`) and
  app-env/live-config; "large spend never halts" Coordinator test through the
  `:runner` seam (SC-001); legacy-record read (settings with `budget_usd` /
  `containment_profile`, `{:needs_human, :breaker}`, clarify `:breaker`)
  through Report, Run Detail, resume, continue (SC-004);
  `RuntimeNotice.container_warning/1`; a sweep test asserting no
  `budget`/`containment_profile` in `RunContext.keys/0`, console forms, and
  `Config` exports (SC-002).
- Drain/supersession tests stay untouched and must pass (FR-019).
