# speckit_orchestrator — Detailed Implementation Plan

**Date:** July 2026 · **Status:** Phases 0–7 complete (2026-07-16); Phase 7 validation passed, only human PR review remains · **Source:** project README + stack verification against upstream releases

This plan turns the README's design into a phased build. It updates every version and API assumption against the state of the ecosystem as of July 2026, resolves or narrows the five "CONFIRM before first run" items, and sequences the work so each phase produces something runnable and testable before the next begins.

---

## 1. Goal and non-goals

**Goal.** An autonomous, spec-driven build pipeline on the BEAM that drives the GitHub Spec Kit loop feature-by-feature through the Claude Code CLI. Control plane = Jido/OTP; data plane = the `claude` CLI wrapped by the `:claude` jido_harness provider. Per-phase model routing, an Opus reviewer standing in for the human at `clarify`, a deterministic `analyze` gate, git-worktree parallelism, and a cost circuit breaker.

**Non-goals for v1.**
- No self-signaling / FSM-strategy agent sequencing (the runner drives the agent synchronously; FSM is a documented later swap).
- No distributed multi-node coordination (single BEAM node; `jido_cluster` is a future option).
- No UI. `iex` + `SpeckitOrchestrator.status()` is the operator surface. (`jido_studio` is a candidate later.)
- No automated merge of feature branches. Converged features stop at "branch ready for human PR review."

---

## 2. Tech stack — July 2026 pins

| Layer | Choice | Version / pin | Notes |
|---|---|---|---|
| Language | Elixir | **1.20.2** | Requires OTP 27+; compatible through OTP 29. v1.20 brings full type inference — run with type checking warnings enabled; it will catch real bugs in `Pipeline` and `Release` for free. |
| Runtime | Erlang/OTP | **28.x** (29 acceptable) | 28 is the safe middle of the supported window. |
| Agent framework | `jido` | **~> 2.2** (Hex) | 2.x is the production line (2.0 shipped March 2026). Do **not** build against 1.x docs — the 2.x API (signal_routes, directives, `Jido.AgentServer.call/2` returning `{:ok, agent}`) is what this design depends on. |
| CLI harness contract | `jido_harness` | GitHub dep, **pinned SHA**, `override: true` | Still explicitly in its "GitHub-dependency phase"; the maintainers instruct sibling adapters to use GitHub deps with `override: true`. Re-check Hex monthly; migrate to Hex the release it lands. |
| Claude adapter | `jido_claude` | Hex beta if resolvable, else GitHub **pinned SHA** | Listed as *beta* on the jido.run ecosystem registry with a Hex link. Prefer Hex; fall back to GitHub SHA. Requires the harness contract version it was built against — keep both pins moving together. |
| Coding agent | Claude Code CLI | latest stable (2.1+) | Installed + authenticated on the host. Verify model aliases resolve on your org allowlist: `claude --model opus -p "print your model id"`. Current-generation aliases route to Opus 4.8 / Sonnet 4.6-class models; pin **full model strings** in config if reproducibility matters more than "latest". |
| Spec workflow | GitHub Spec Kit (`specify` CLI) | **v0.12.x** (v0.12.11 at time of writing) | Major CLI churn since early 2026 — see §4. Install via `uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v0.12.11`. |
| Spec Kit bootstrap | `specify init . --integration claude` | — | The `--ai` flag family was **removed in v0.10.0**. Claude Code is now a skills-capable integration; `--integration-options="--skills"` installs agent skills under `.claude/skills/` instead of slash-command prompt files. |

**mix.exs deps sketch:**

```elixir
defp deps do
  [
    {:jido, "~> 2.2"},
    {:jido_harness, github: "agentjido/jido_harness", ref: "<PINNED_SHA>", override: true},
    # Prefer: {:jido_claude, "~> 0.x"} once the Hex beta resolves cleanly; otherwise:
    {:jido_claude, github: "agentjido/jido_claude", ref: "<PINNED_SHA>"}
  ]
end
```

Record both SHAs in the README and bump them deliberately (a `mix speckit.deps.audit` alias that diffs pinned SHA vs upstream `main` is a cheap Phase-7 nicety).

---

## 3. CONFIRM list — resolution status

The README flagged five items to confirm because jido_claude's README was unreachable when it was written. Current status:

| # | Item | Status | Resolution |
|---|---|---|---|
| 1 | `Jido.Claude.Adapter` module name in config | **Likely unnecessary** | jido_harness auto-discovers loaded adapter modules ("auto-discovery is non-invasive: modules are used only if they are loaded and expose a supported run API"). Verify at boot with `Jido.Harness.providers()` — expect `:claude` in the list. Only add explicit provider registration if discovery fails. |
| 2 | `RunRequest` fields (`model`, `max_turns`, `provider_options` for `permission_mode`/`allowed_tools`) | **Partially confirmed — verify pass-through** | `Jido.Harness.RunRequest.new!(%{prompt: ...})` and `run_request(:claude, request, transport: :exec)` are the confirmed entry points, and `Jido.Harness.capabilities(:claude)` exists to interrogate what the adapter supports. Whether Claude-native permission options ride through `provider_options` must be verified against the adapter's `docs/adapter_contract.md` + source in Phase 2. Fallback stands: the repo's committed `.claude/settings.json` enforces scope regardless. |
| 3 | Event shapes in `RunPhase.reduce/1` | **Pattern confirmed — map fields in Phase 2** | Sibling adapters emit normalized harness event structs plus provider-extended types (Codex uses `:codex_*` names → expect `:claude_*` extensions). One sibling (OpenCode) is buffered-first (`streaming?: false`); confirm whether jido_claude streams or buffers, and make `reduce/1` agnostic to both by consuming the returned enumerable uniformly. |
| 4 | `Jido.AgentServer.state/1` in `status/0` | **Design-critical API confirmed** | `Jido.AgentServer.call(pid, signal)` is synchronous and returns `{:ok, agent}` — the runner-drives-agent design is safe. For `status/0`, Jido 2.2 exposes instance-level introspection (`list_agents`, `whereis`, agent count); if a direct `state/1` isn't public, use the planned no-op signal call. Decide in Phase 3, one-line change either way. |
| 5 | `Backlog.extract_prereqs/1` regex vs breakdown wording | **Still yours to align** | This depends on your own `macro-spec-breakdown` output format. Phase 1 includes a golden-file test suite over your real `docs/breakdown/NNN-*.md` files so DAG extraction is proven before anything runs. |

---

## 4. Spec Kit v0.10 → v0.12 migration impacts (new since the README)

These are the changes that materially affect the orchestrator design:

1. **CLI surface churn.** `specify init <dir> --ai claude` no longer exists. Bootstrap is now `specify init . --integration claude` (add `--integration-options="--skills"` for skills mode). Any docs, scripts, or runbooks must use the new flags. `specify self check` / `specify self upgrade` now exist — bake `self check` into the orchestrator's preflight.
2. **Claude Code integration is skills-based.** Spec Kit installs its commands for Claude under `.claude/skills/` (invocable as `/speckit.specify`, `/speckit.plan`, etc., or as skills). Consequence for `RunPhase`: the prompt sent through the harness should invoke the Spec Kit command by its slash/skill name and rely on the CLI's own discovery — do not hardcode paths to prompt files, which moved between 0.9 → 0.12.
3. **Constitution overwrite hazard.** `specify init --here --force` is documented to overwrite `.specify/memory/constitution.md` with the default template. The orchestrator must **never** run `specify init` with `--force` inside a worktree; worktrees inherit the committed `.specify/` tree from the repo, which is the correct behavior anyway. Add a preflight assertion that `constitution.md` is committed and non-default.
4. **Extensions/presets.** The git extension is opt-in (`specify extension add git`). Decide once in the base repo whether it's installed; worktrees inherit it. The orchestrator itself owns branching via `Worktree`, so the git extension is likely *off* to avoid double-driving git.
5. **No native task parallelism in Spec Kit.** `implement` still executes sequentially inside one agent session. Worktree-level parallelism across features remains the orchestrator's core value-add; nothing in 0.12 obsoletes it.
6. **Version discipline.** Spec Kit ships releases weekly. Pin the `specify` CLI to a tag in the prerequisites doc, and record the tag in `config.exs` so `analyze` output format drift is diagnosable.

---

## 5. Phased delivery plan

Each phase ends with a demoable checkpoint and explicit exit criteria. Order matters: pure logic first, harness second, orchestration third, autonomy last.

### Phase 0 — Environment, spike, and contract verification (1–2 days)

Stand up the toolchain and burn down the CONFIRM list with a throwaway spike project.

Tasks:
1. Install Elixir 1.20.2 / OTP 28 (asdf or mise; commit `.tool-versions`).
2. Install and authenticate the Claude Code CLI; verify `claude --model opus -p "print your model id"` and the same for `sonnet` against your org allowlist. Record the resolved model IDs.
3. Install `uv`, then `specify` CLI pinned to v0.12.x; run `specify self check`.
4. Initialize the **target repo** (not the orchestrator): `specify init . --integration claude`, write a real `constitution.md`, commit `.specify/` + `.claude/`.
5. Create a spike Mix project with the three deps; run `Jido.Harness.providers()` and `Jido.Harness.capabilities(:claude)` in iex. Record output.
6. Run one end-to-end manual harness call: `Jido.Harness.run(:claude, "/speckit.specify <tiny feature>", cwd: repo)`. Inspect the event stream/list shape and the final result struct.
7. From the adapter source + `docs/adapter_contract.md`, document: RunRequest fields honored, `provider_options` pass-through (or lack of it), event struct fields, session id location (needed for `cancel/2`), streaming vs buffered, and cost/usage fields if surfaced.

**Exit criteria:** a one-page `docs/harness-contract.md` in the orchestrator repo that pins the answers to CONFIRM items 1–3 with actual observed structs. No orchestrator code depends on guesses after this point.

### Phase 1 — Pure core: Backlog, Pipeline, Config, Ledger (2–3 days)

Everything in this phase is pure or a plain GenServer — fully testable without the CLI.

Tasks:
1. `config.ex` — typed accessors over `config/config.exs`: `repo`, `breakdown_dir`, `worktree_root`, `models` (per phase, full model strings preferred), `plan_stack`, `max_concurrency`, `budget_usd`, `implement_max_turns`, `speckit_version`.
2. `backlog.ex` — parse `docs/breakdown/NNN-*.md` → `%Feature{id, slug, path, prereqs, status}`. Replace the heuristic regex with a parser tuned to your breakdown skill's actual "Prerequisites" section; add golden-file tests over your real breakdown output (CONFIRM #5 closed here). Detect cycles and fail loudly at load.
3. `pipeline.ex` — the pure transition table: `specify → clarify → plan → tasks → analyze → implement → converge → done`, with `Pipeline.next/3` handling the clarify gate (`## NEEDS HUMAN` → `:escalated`) and analyze gate (Critical finding → `:halted`). Exhaustive unit tests: every phase × every outcome.
4. `ledger.ex` — cost circuit-breaker GenServer: `reserve/2`, `record/2`, `breaker_tripped?/0`. Property test: recorded spend never exceeds budget + one in-flight reservation.
5. `release.ex` — pure release policy: given features + statuses + concurrency cap + breaker state, return the next wave. Escalated/failed prereqs block dependents. Table-driven tests including diamond dependencies and breaker mid-run.

Elixir 1.20 note: compile with warnings-as-errors; the new type inference will verify the transition table's tuple/atom shapes across `Pipeline`, `Release`, and the actions for free.

**Exit criteria:** `mix test` green with >90% coverage on these five modules; `Backlog` parses your real breakdown folder into the expected DAG.

### Phase 2 — Data plane: RunPhase against the real harness (3–4 days)

Tasks:
1. `actions/run_phase.ex` (Jido.Action) — builds a `Jido.Harness.RunRequest` from `(feature, phase, config)`: prompt = the `/speckit.<phase>` invocation + phase-specific instructions; `cwd` = the feature worktree; `model` from per-phase config; `max_turns` for implement; `provider_options` per Phase 0 findings.
2. `RunPhase.reduce/1` — fold the event enumerable into `%PhaseResult{final_text, session_id, cost_usd?, tool_events, raw}`. Written against the observed structs from Phase 0; tolerant of both streamed and buffered adapters. Provider-extended `:claude_*` event types are captured but not required.
3. Deterministic `analyze` parsing — the analyze phase runs read-only; the prompt instructs the model to end with a single JSON line; `RunPhase` (or a dedicated `AnalyzeResult` module) parses it in Elixir and classifies findings. Malformed JSON = phase failure, not a silent pass. Unit-test the parser with fixture outputs including sneaky cases (JSON mid-transcript, fenced JSON, trailing prose).
4. Clarify prompt pack — the Opus reviewer prompt: resolve ambiguities from constitution + macro-spec, write `## Clarifications` into the spec, emit `## NEEDS HUMAN` for anything underivable. Keep prompts in `priv/prompts/*.md`, versioned.
5. Cost extraction — if the adapter surfaces usage/cost events, wire them to `Ledger.record/2`; if not, fall back to a conservative per-phase flat estimate from config (documented as such).
6. Integration test tier — `@tag :integration` tests that run one real phase against a fixture repo, excluded by default (mirrors the adapter repos' own convention). Add `mix claude.compat`-style preflight to CI docs if the adapter ships it.

**Exit criteria:** `RunPhase` executes `specify` and `analyze` for one toy feature in a fixture repo end-to-end from iex, with cost recorded in the Ledger and the analyze JSON parsed deterministically.

### Phase 3 — Feature vertical: Worktree, FeatureAgent, FeatureRunner (3–4 days)

Tasks:
1. `worktree.ex` — `create/1` (branch `feature/NNN-slug` + `git worktree add` under `worktree_root`), `remove/1`, `keep_for_inspection/1`. Assert `.claude/settings.json`, `.claude/skills/` (Spec Kit skills), and `.specify/` are present in the worktree (they are, if committed — Phase 0 step 4). Never run `specify init` inside a worktree (§4.3).
2. `feature_agent.ex` — Jido.Agent with schema (`feature`, `worktree`, `phase`, `history`, `status`) and `signal_routes: [{"feature.init", InitFeature}, {"phase.run", RunPhase}]`.
3. `actions/init_feature.ex` — seed feature + worktree into agent state.
4. `feature_runner.ex` — supervised Task under `RunnerSup` (Task.Supervisor): start the agent via the app's Jido instance, then loop: `Jido.AgentServer.call(pid, Jido.Signal.new!("phase.run", %{}, source: "/runner"))` → inspect returned agent → `Pipeline.next/3` → continue / escalate / halt / converge. On terminal status, notify the Coordinator and clean or keep the worktree.
5. `status/0` plumbing decision (CONFIRM #4): use the public introspection API if agent state is readable; else a no-op `"status.read"` signal route. One line either way.
6. Timeouts + crash semantics: `call` timeout per phase from config (implement phases are long — default generous, e.g. 30–60 min); a crashed runner marks the feature `:failed` via the Coordinator's monitor, never retries silently.

**Exit criteria:** one feature runs the full pipeline autonomously in its own worktree from `FeatureRunner.run/1`, ending `:done`, `:escalated`, or `:halted` with the worktree kept on non-done.

### Phase 4 — Control plane: Coordinator + release waves (2–3 days)

Tasks:
1. `coordinator.ex` — Jido agent holding the run state (features map, statuses, in-flight set) with client API `start_run/0`, `notify/2`, `status/0`.
2. `actions/start_run.ex` — load backlog, validate DAG, release the first wave via `Release`, spawn runners (as directives or via the runner supervisor from the action's context — pick one and document the purity boundary: spawning belongs to directives/runtime, not action bodies).
3. `actions/feature_finished.ex` — record terminal status, consult `Release`, spawn next wave; stop when nothing is releasable; final report (done/escalated/halted/blocked lists + total spend).
4. `application.ex` — supervision tree: `Ledger`, `{Task.Supervisor, name: SpeckitOrchestrator.RunnerSup}`, `SpeckitOrchestrator.Jido` (the `use Jido, otp_app:` instance). Coordinator started per-run, not at boot.
5. Breaker integration — `Release` consults `Ledger.breaker_tripped?/0`; a tripped breaker drains in-flight features (they finish their current phase, then halt) rather than killing mid-phase.
6. `SpeckitOrchestrator.run/0` / `status/0` facade.

**Exit criteria:** a 3-feature backlog with one dependency chain runs with `max_concurrency: 2`; waves release correctly; killing a runner mid-run marks the feature failed and blocks its dependents; tripping the breaker (tiny `budget_usd`) drains cleanly.

### Phase 5 — Enforcement and containment (2 days)

Tasks:
1. `.claude/` pack for the **target repo**: `settings.json` with least-privilege `allowed_tools`/permissions per your CLI version's schema, plus the PreToolUse scope-guard hook (deny writes outside the worktree, deny dangerous Bash). Committed so it travels into every worktree.
2. Reconcile with Spec Kit's skills files (also under `.claude/`) — ensure `specify` upgrades don't clobber your settings/hooks; document the upgrade procedure (back up constitution per §4.3; re-diff `.claude/` after `specify init` refreshes).
3. If Phase 0 showed `provider_options` pass-through works, set `permission_mode`/`allowed_tools` per phase in `RunPhase` too (analyze = read-only tool set; implement = scoped write set). Belt and suspenders with the settings file.
4. Container option (defense in depth, optional for v1): a docs recipe for running the whole orchestrator + CLI inside a devcontainer/Docker with the repo mounted, since the PreToolUse hook has known enforcement gaps on some CLI versions.
5. Red-team test: an integration test where the prompt tries to write outside the worktree; assert denial.

**Exit criteria:** scope-guard demonstrably blocks out-of-tree writes in a live run; documented settings survive a `specify` upgrade.

### Phase 6 — Observability, docs, and operator ergonomics (2 days)

Tasks:
1. Telemetry: emit `[:speckit, :phase, :start|:stop|:exception]` and `[:speckit, :feature, :terminal]` events with feature id, phase, duration, model, cost. Jido 2.x ships telemetry conventions — align names where they exist.
2. Structured logging: one log line per phase transition; transcript files per phase under `worktree/.speckit_logs/` for post-mortems.
3. `status/0` output: per-feature phase, elapsed, spend, and run totals; render as a simple table in iex.
4. Docs: `docs/runbook.md` (start, watch, respond to escalations, resume after human resolution), `docs/harness-contract.md` (from Phase 0), README refresh with the v0.12 Spec Kit flags.
5. Escalation workflow: `SpeckitOrchestrator.resolve(feature_id)` to mark a human-resolved feature releasable again on the next run (v1: re-run the feature from `clarify`; state resumption mid-pipeline is v2).

**Exit criteria:** an operator who didn't build the system can run, watch, and unblock a run from the runbook alone.

### Phase 7 — Greenfield validation run ("LedgerLite") and hardening (gate before fleet mode)

> **✅ DONE (2026-07-16).** Every automated exit criterion below was met against
> the LedgerLite target (`../ledgerlite`, Python 3 stdlib). Features 001–006 built
> end-to-end with passing tests (109 / 202 / 260 / 220 / 243, plus 005); 007
> escalated at `clarify` on the seeded month-end/proration/edit trap; the analyze
> gate halted on a constitution Critical both injected (float in 001) and natural
> (002's forced money path); the wave shape ran solo → parallel → three-vs-cap-2
> contention; and the breaker drained cleanly on real spend (in-flight feature
> finished its phase then halted, correct tally, spend within budget + one
> reservation). The run surfaced **seven orchestrator fixes** (see CLAUDE.md).
> The only remaining item is human PR review of the feature branches — an
> inherently manual gate, not an orchestrator capability.

The pilot does not run against a real product first. It runs against a purpose-built greenfield target — **LedgerLite** — designed so that every orchestrator mechanism is exercised deliberately, including the failure paths, on a cheap and disposable codebase.

#### 7.1 The validation target

LedgerLite is a local-first personal expense tracker CLI: add expenses, categorize them, set monthly budgets, produce reports, import/export CSV. It is intentionally boring as a product and interesting as a pipeline exercise: single persona, small logical data model (Expense, Category, Budget, RecurringRule), no auth, no external APIs, no servers binding ports — so parallel worktrees cannot contaminate each other and token spend stays small.

It is produced through the same front door as any real project: macro-spec interview → macro-spec folder → macro-spec-breakdown → `docs/breakdown/NNN-*.md` → `SpeckitOrchestrator.run()`. This validates the *whole* chain, including `Backlog.extract_prereqs/1` against real breakdown output (closing the loop on CONFIRM #5 with production-shaped input).

**Feature set and dependency DAG** (7 features, 3 waves at `max_concurrency: 2`):

| # | Feature | Prereqs | Wave | Validates |
|---|---|---|---|---|
| 001 | Core ledger (model, storage, add/list) | — | 1 | Full pipeline happy path, solo wave |
| 002 | Categories (manage, assign) | 001 | 2 | Parallel worktree isolation (with 005) |
| 005 | CSV import/export | 001 | 2 | Parallel worktree isolation (with 002) |
| 007 | Recurring expenses — **seeded clarify trap** | 001 | 2→3 | Concurrency cap (waits behind 002/005), then clarify escalation |
| 003 | Budgets (monthly caps, warnings) | 002 | 3 | Wave release after dependency completes |
| 004 | Reports (monthly category summary) | 002 | 3 | Three releasable vs cap of two — contention |
| 006 | Search & filter (date range, category) | 002 | 3 | Blocked-dependent behavior if 002 escalates/fails |

**Seeded traps — the point of the exercise:**

1. **Clarify trap (007).** The breakdown file for recurring expenses deliberately says "handled sensibly across months" without specifying proration, end-of-month semantics (Jan 31 → Feb ?), or edit behavior — and neither the constitution nor the macro-spec answers it. The Opus clarify reviewer *should* emit `## NEEDS HUMAN` and escalate. If it confidently invents an answer instead, the rubber-stamping risk has been measured on a cheap target. Track the NEEDS HUMAN outcome as a hard pass/fail.
2. **Analyze trap (constitution).** The constitution carries checkable MUSTs: monetary amounts are stored and computed as integer cents (floating-point money forbidden); every command has tests; no network access; exit codes 0/1 only; plain-text deterministic output. The integer-cents rule is exactly the kind Sonnet violates casually during `implement`; the deterministic analyze gate must catch it as a Critical and halt the feature. If no violation occurs naturally in the run, inject one (a planted `float` money path in a fixture branch) to prove the gate fires.
3. **Breaker drill.** Set `budget_usd` to roughly five features' worth of estimated spend so the Ledger breaker trips mid-run; verify in-flight features drain (finish their current phase, then halt) rather than being killed, and that the final report accounts for done/halted/blocked correctly.
4. **Blocking drill (optional second run).** Move the seeded ambiguity from 007 into 002 and re-run: 003, 004, and 006 must all block behind the escalation, and `resolve/1` must release them after human resolution.

#### 7.2 Run protocol

1. First run at `max_concurrency: 1` with a small budget: features 001 → 002, confirming the sequential happy path end-to-end before any parallelism.
2. Second run at `max_concurrency: 2` for the full backlog: verify wave shape (001 alone; 002+005 while 007 waits; three-way contention in wave 3), the clarify escalation on 007, and the breaker drill.
3. Human PR review of **every** LedgerLite feature branch (the rubber-stamp risk is real: two same-family models reviewing each other; the analyze gate is the backstop, not a substitute for early human review). Review cost is low precisely because the product is trivial.
4. Tune from evidence: per-phase `max_turns`, timeouts, clarify prompt (measure NEEDS HUMAN rate — too low is as suspicious as too high), analyze JSON schema.
5. Only after LedgerLite passes: repeat the pilot on one real feature from the real product backlog, in a branch-protected repo, before raising concurrency for fleet mode.
6. Monthly dependency ritual: re-check jido_harness/jido_claude for Hex releases; `specify self check`; re-run the Phase 0 contract verification if any pin moves.

**Exit criteria (all must hold):** all seven features reach a terminal state with no orchestrator crashes; 007 escalates at clarify with `## NEEDS HUMAN` (worktree kept for inspection); the analyze gate halts on a constitution Critical at least once (natural or injected); wave releases match the DAG and concurrency cap exactly; the breaker drains cleanly with a correct final report; total spend lands within budget + one reservation; and every merged feature passes human PR review with working tests. Keep the LedgerLite repo as a permanent regression fixture — re-run it after any dependency pin bump.

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| jido_harness/jido_claude API churn (pre-Hex, fast-moving) | High | Medium | SHA pinning; Phase 0 contract doc; all harness knowledge isolated in `RunPhase` + one contract module. |
| Spec Kit CLI/format churn (weekly releases; `--ai` removal precedent) | High | Medium | Pin `specify` tag; record in config; preflight `specify self check`; prompts invoke commands by name, never by file path. |
| `provider_options` not passed through → weaker per-phase permissions | Medium | Medium | Committed `.claude/settings.json` + hook is the layer that works regardless; container recipe for defense in depth. |
| Same-family reviewer rubber-stamping at clarify | Medium | High | Deterministic analyze gate on constitution MUSTs; human PR review for early features; monitor NEEDS HUMAN rate. |
| Cost overrun | Medium | High | Ledger breaker with reservations; per-phase `max_turns`; drain-don't-kill semantics; pilot with small budget. |
| Analyze JSON drift/malformed output | Medium | Medium | Strict parser, malformed = failure; fixture tests; schema stated in the prompt and versioned. |
| Constitution clobbered by Spec Kit upgrade | Low | High | Never `--force` in worktrees; backup step in runbook; constitution committed and diffed in CI. |
| Worktree cross-contamination (caches, ports) | Medium | Low–Med | Per-worktree env vars; document project-specific isolation; start at concurrency 1. |

---

## 7. Testing strategy summary

- **Unit (default `mix test`)**: Pipeline transitions (exhaustive), Release waves (table-driven incl. cycles/diamonds/breaker), Backlog golden files, Ledger properties, analyze-JSON parser fixtures. No CLI needed; runs in CI.
- **Integration (`--include integration`)**: real harness calls against a fixture Spec-Kit repo — one per phase type plus the scope-guard red-team test. Requires authenticated CLI; run locally/nightly, mirroring the adapter repos' own opt-in convention.
- **End-to-end validation**: Phase 7's LedgerLite run — full backlog with seeded clarify/analyze traps, breaker drill, and blocking drill; every branch human-reviewed. Kept as a permanent regression fixture for dependency bumps.
- **Type checking**: Elixir 1.20 inference with warnings-as-errors as a standing static gate.

---

## 8. Indicative timeline

| Phase | Duration | Cumulative |
|---|---|---|
| 0 — Environment + contract spike | 1–2 d | ~2 d |
| 1 — Pure core | 2–3 d | ~1 wk |
| 2 — RunPhase vs real harness | 3–4 d | ~1.5 wk |
| 3 — Feature vertical | 3–4 d | ~2.5 wk |
| 4 — Coordinator + waves | 2–3 d | ~3 wk |
| 5 — Enforcement | 2 d | ~3.5 wk |
| 6 — Observability + docs | 2 d | ~4 wk |
| 7 — LedgerLite validation run + hardening | 3–5 d of runs/review, then ongoing | gate to fleet mode |

Single experienced Elixir engineer, part-time-friendly; phases 1 and 2 can overlap once Phase 0's contract doc exists. The LedgerLite macro-spec + breakdown can be produced any time from Phase 1 onward (it doubles as the golden-file input for `Backlog` tests), so Phase 7 starts the moment Phase 6 exits.

---

## 9. Open questions for the project owner

1. Hex vs GitHub for `jido_claude`: if the Hex beta resolves against your pinned `jido_harness` SHA, prefer it — confirm compatibility in Phase 0.
2. Full model strings vs CLI aliases (`opus`/`sonnet`): aliases track "latest" (currently Opus 4.8 / Sonnet 4.6 class) and can shift under you mid-run; full strings are reproducible. Recommendation: full strings in config, alias check only as a preflight.
3. Skills mode vs slash-command mode for the Spec Kit Claude integration (`--integration-options="--skills"`): pick one in Phase 0 and verify the harness-driven CLI invokes it headlessly; document the choice.
4. Should `converge` include an automated `git merge --no-ff` into an integration branch, or stop at "branch ready"? v1 plan assumes stop-at-branch.
5. Escalation resume granularity: v1 re-runs from `clarify` after human resolution — acceptable, or is mid-pipeline resume a v1 requirement?
