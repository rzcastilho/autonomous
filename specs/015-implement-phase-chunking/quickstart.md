# Quickstart: validating Implement Phase Chunking

**Branch**: `015-implement-phase-chunking` |
**Plan**: [plan.md](./plan.md) | **Contracts**: [contracts/](./contracts/)

Runnable validation of the feature end-to-end. Scenario numbers map to the
spec's success criteria; each states its expected outcome so a failure is
unambiguous. Implementation detail lives in the contracts, not here.

---

## Prerequisites

```bash
mise exec -- elixir --version     # expect Elixir 1.20.2 / OTP 28
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON — must be clean
```

For the live scenarios (S5–S7) you also need:

- a target Spec Kit repo with the committed pack (`TargetPack.verify/1` clean)
  and an `origin` remote — `../quickpoll` is the repo the 2026-07-25 failure was
  observed on;
- `claude` on `PATH`, authenticated;
- `config :speckit_orchestrator, repo: "../quickpoll"` (or the equivalent env
  override in `config/runtime.exs`).

---

## S1 — Unit suite (pure core)

```bash
mise exec -- mix test test/speckit_orchestrator/task_plan_test.exs \
                      test/speckit_orchestrator/chunking_test.exs
```

**Expect**: green. Covers the parser grammar
([contracts/task_plan.md §3](./contracts/task_plan.md)) and every row of the
decision table ([contracts/chunking.md §2](./contracts/chunking.md)), including
the golden parse of this repo's own
`specs/014-recovery-reconciliation/tasks.md` — that test failing means the
upstream tasks template drifted and the fallback path would silently take over.

## S2 — Full hermetic suite + coverage

```bash
mise exec -- mix test
mise exec -- mix test --cover
```

**Expect**: green, with **no pre-existing test modified to accommodate the
change**. Specifically these must pass untouched, because each guards an
invariant this feature could quietly break:

| Test | Guards |
|---|---|
| `checkpoint_test.exs` | pre-015 checkpoints still readable (no `implement_chunk`) |
| `recovery/evidence_test.exs` | task-phase commits are **not** phase boundaries (R5) |
| `pipeline_test.exs` | the seven-step model and its gates (FR-008) |
| `telemetry_test.exs` | existing `[:speckit, :phase, …]` span unchanged |

Coverage on the pure core stays >90% (constitution, Quality & Test Discipline);
`task_plan.ex` and `chunking.ex` are pure and should sit near 100%.

## S3 — SC-005: unstructured task lists are untouched

```bash
mise exec -- mix test test/speckit_orchestrator/phase_request_test.exs \
                      test/speckit_orchestrator/web/
```

**Expect**: the `:whole_list` implement prompt is asserted **byte-identical** to
today's bare `/speckit.implement`, and the rendered phase strip for a feature
with no task-phase structure is asserted markup-identical to the pre-change
render — no `1/1`, no empty separator (FR-019).

## S4 — SC-002: every failure names exactly one cause

```bash
mise exec -- mix test test/speckit_orchestrator/chunking_test.exs --only sc002
```

**Expect**: the four reasons — stuck task-phase, exhausted session budget,
unchecked tasks after the sweep, non-exhaustion cause — are produced by distinct
paths and the reason→sentence mapping is total
([contracts/chunking.md §3](./contracts/chunking.md)).

---

## S5 — SC-001: the exact production case (live)

The 2026-07-25 failure: 18 tasks across 5 task-phases, `implement_max_turns: 80`,
previously cut off after 8 tasks in 81 turns.

```bash
mise exec -- iex -S mix
```

```elixir
SpeckitOrchestrator.Telemetry.attach_default_logger()
{:ok, _pid} = SpeckitOrchestrator.run(features: [feature_001])
SpeckitOrchestrator.print_status()
```

**Expect**:

- 5 chunk sessions dispatched in task-phase order (log:
  `task-phase 1/5 …` … `task-phase 5/5 …`);
- feature reaches `:done`; **all 18 tasks marked `[X]`** in the worktree's
  `tasks.md`;
- durable transcripts under
  `<transcript_root>/001/`: `06-implement-p01-a1.md` … `06-implement-p05-a1.md`
  plus the `06-implement.md` roll-up, **and `07-converge.md` still present**
  (R6 regression);
- `git log` on `feature/001-…` after `:done` shows **one** squashed commit —
  task-phase commits collapsed (FR-023b).

## S6 — SC-003 + FR-016/017: operator visibility (live)

```bash
mise exec -- mix phx.server   # then open http://127.0.0.1:4000/
```

While S5 runs, on Mission Control:

**Expect**:

- the feature's `implement` cell shows `3/5 · User Story 1` and updates within
  5s of each boundary;
- the activity feed carries one boundary entry per task-phase naming both sides
  (`task-phase 2/5 "…" complete → 3/5 "…"`);
- a continuation attempt appears as a `:warn` entry naming the attempt number.

Stop the server mid-run and reload: the implement cell still shows the last
known task-phase, reconstructed from the checkpoint (FR-018).

## S7 — SC-004: resume at the failing task-phase (live)

Force a failure during task-phase 3 of 5 (e.g. temporarily set
`implement_max_turns: 3` and `implement_no_progress_limit: 1`), then on
`/escalations`:

**Expect**:

- the checkpoint block shows `implement_chunk` with ordinal/number/title and
  `sessions_used`;
- the resume form offers a **task-phase select** defaulting to task-phase 3,
  with completed task-phases marked `✓`;
- after resuming: the first dispatched session is scoped to task-phase 3;
  **zero** tasks from task-phases 1–2 are re-executed; their `[X]` marks and
  their code survive the pre-resume `Worktree.restore/1` because each boundary
  was committed (FR-023a — this is the load-bearing check);
- `sessions_used` restarts at 0 (FR-013b).

Then renumber the task-phases in `tasks.md` (shift the numbers, keep the titles)
and resume again: the picker notes the match was by **title**, and a `:warn` feed
entry says so (FR-025a).

## S8 — SC-007: cost overhead ≤20%

Pick a feature that previously completed `implement` in a single session. Run it
before and after this change against the same target commit, and compare the
`implement` spend reported by `SpeckitOrchestrator.print_status()` /
`Ledger.snapshot/1`.

**Expect**: post-change implement spend ≤ 1.20 × pre-change. Record both figures
in the run notes; if exceeded, the knob is `implement_max_turns` (fewer, larger
chunks) — not disabling chunking.

---

## Configuration reference

| Key | Default | Meaning |
|---|---|---|
| `implement_max_turns` | `80` | per-**session** turn cap; now per task-phase (unchanged value) |
| `implement_no_progress_limit` | `2` | consecutive no-progress attempts on one task-phase before it is stuck (FR-013) |
| `implement_sessions_per_task_phase` | `2` | ceiling formula multiplier (FR-013a) |
| `implement_sessions_headroom` | `4` | ceiling formula constant; ceiling = `2 × task_phases + 4` |
| `phase_max_retries` | `1` | **unchanged** — transient server/API drops only (FR-014) |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| One session runs over the whole task list on a structured feature | `tasks.md` headings don't match `## Phase <n>: <title>` — run S1's golden test |
| Recovery resumes a chunked feature at `converge` | a task-phase commit subject matched `Recovery.Evidence`'s boundary regex (R5) |
| `07-converge.md` missing after a chunked run | chunk transcripts consumed step numbers (R6) |
| Feature fails with `unchecked_tasks` on a hand-written list | expected under R9 — the reason names the tasks; confirm they are genuinely unbuilt before raising limits |
| Feature spend double-counted in the console | the implement phase-stop clause is adding chunk costs again ([contracts/telemetry-chunk.md §2](./contracts/telemetry-chunk.md)) |
