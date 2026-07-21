# Quickstart: Self-Sufficient Resume

Validation scenarios proving the two defects are fixed. Run everything through
mise. See [data-model.md](./data-model.md), [contracts/](./contracts/) for shapes.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile        # warnings_as_errors ON — must be clean
```

Hermetic scenarios use the existing test seams — `:features`, `:runner`,
`:executor`, and `Application.put_env/3` for `Config` — so no CLI, worktree, or
`gh` is required. `Config.transcript_root/0` is redirected to a tmp dir per test.

## Scenario 1 — Resume from the feature id alone (Story 1, SC-001)

**Proves**: FR-001/002/004 — identity recovered from the checkpoint; no hand-typed
identity, no backlog required.

1. Write a checkpoint for id `"042"` carrying `slug: "widget"`, `path:
   ".../042-widget.md"`, a valid `last_phase`, and status `:halted` (via
   `Checkpoint.write/1` or by driving a fake feature to a diverted terminal).
2. Call `SpeckitOrchestrator.resume("042", features: [], runner: fake_runner)`
   — **no explicit feature**, empty backlog.
3. **Expect**: the fake runner receives a `%Feature{id: "042", slug: "widget",
   path: ".../042-widget.md"}` and starts at the checkpointed phase. No
   `{:unknown_feature, _}` despite the empty backlog.

Optional guidance note (acceptance 2): add `prompt: "focus on X"`; assert it is
carried as `resume_prompt` into the resumed phase, identity still from checkpoint.

## Scenario 2 — Resume reuses the original run context (Story 2, SC-002)

**Proves**: FR-006/007/009 — a PR-workflow run's context survives into a resume in a
fresh env.

1. `Application.put_env(:speckit_orchestrator, :pr_workflow, false)` (live default
   OFF, simulating the fresh invocation env).
2. Write a checkpoint for id `"050"` whose `context` records `pr_workflow: true`
   (plus e.g. `max_concurrency: 1`, `budget_usd: 10.0`, `pr_base: "develop"`).
3. Call `resume("050", features: [], executor: fake_executor)`.
4. **Expect**: resume routes through the **PR-workflow path** — cap 1, stacking, and
   PR-on-`:done` — even though live `pr_workflow` is `false`. The recorded value
   beats live Config (FR-007). `budget_usd`/`pr_base` are likewise reapplied.

Non-PR settings (acceptance 2): a checkpoint recording `max_concurrency: 3` /
`budget_usd: 7.5` resumes under those, not the compile-time defaults.

## Scenario 3 — Explicit override beats recorded context (FR-007, acceptance 3)

1. Checkpoint for `"051"` records `pr_workflow: true`.
2. Call `resume("051", pr_workflow: false, runner: fake_runner)`.
3. **Expect**: the explicit `pr_workflow: false` wins — resume runs the non-PR path.
   A human can still deliberately reshape a resumed run.

## Scenario 4 — Old / partial checkpoint falls back, observably (FR-008, SC-004)

1. Checkpoint for `"052"` with **no** `context` key (pre-007 shape) but valid
   identity + phase.
2. Call `resume("052", features: [], runner: fake_runner)`.
3. **Expect**: resume succeeds via fallback to live Config; a `Logger.info` line
   names the fallen-back settings (capture with `ExUnit.CaptureLog`); no crash.
4. Partial variant: `context` recording only `pr_workflow: true` (others absent) →
   `pr_workflow` reapplied, the rest fall back + logged.

## Scenario 5 — Distinct failure outcomes preserved (FR-005, SC-003)

Assert each still starts no run and returns its own atom:

| Setup | `resume(id, …)` result |
|-------|------------------------|
| no checkpoint file | `{:error, :no_checkpoint}` |
| corrupt checkpoint (non-object JSON) | `{:error, :corrupt_checkpoint}` |
| checkpoint `last_phase` not a real phase (or bad `:from`) | `{:error, {:unknown_phase, _}}` |
| neither explicit/backlog feature nor identity in checkpoint | `{:error, {:unknown_feature, id}}` |
| valid checkpoint, existing-branch worktree gone | feature `:failed` with `{:worktree, :branch_missing}` |

## Scenario 6 — Best-effort write with new fields (FR-010, SC-005)

Point `transcript_root` at an unwritable path; drive a diverted terminal so
`Checkpoint.write/1` runs with `slug`/`path`/`run_context` present. **Expect**: the
run still reaches its terminal result and `write/1` returns `:ok` (rescued) — adding
identity/context introduced no new break.

## Full suite

```bash
mise exec -- mix test                          # hermetic default suite
mise exec -- mix test --cover                  # confirm RunContext + resume >90% core
mise exec -- mix test --include integration    # opt-in real-harness paths
```
