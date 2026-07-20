# Quickstart: Resume Facade

Validates that `SpeckitOrchestrator.resume/2` restarts one feature at its
checkpointed phase, honors overrides/guidance, and fails loud on every unsafe
precondition. See [contracts/resume.md](./contracts/resume.md) for the full
contract and [data-model.md](./data-model.md) for the resolution flow.

## Prerequisites

- Toolchain via mise (Elixir 1.20.2-otp-28): all commands run as `mise exec -- …`.
- Prerequisite features present: 001 checkpoint persistence, 002 runner resume
  entry point, 003 operator prompt injection.

## Unit validation (hermetic — default suite)

Uses the `:runner` seam (a fake runner) and a fixture checkpoint — no CLI, no
worktree, no git. This is the primary validation path (Constitution: pure/seam
tests, >90% coverage).

```bash
mise exec -- mix test test/speckit_orchestrator/resume_test.exs
```

Expected: all scenarios green, including —

- **Default resume**: fixture checkpoint at `analyze` ⇒ fake runner receives
  `start_phase: :analyze` (not `Pipeline.first()`). (SC-002)
- **Guidance passthrough**: `resume(id, prompt: "…")` ⇒ the fake runner sees the
  prompt reach the resumed phase unchanged; no `:prompt` ⇒ `resume_prompt: nil`,
  no error. (SC-003)
- **`:from` override**: `resume(id, from: :plan)` ⇒ runner starts at `:plan`.
- **Distinct failures, no run started** (assert the fake runner is never
  invoked):
  - no checkpoint ⇒ `{:error, :no_checkpoint}`
  - corrupt checkpoint ⇒ `{:error, :corrupt_checkpoint}`
  - unknown id ⇒ `{:error, {:unknown_feature, id}}`
  - bogus `:from` ⇒ `{:error, {:unknown_phase, :nope}}`

## Full test suite (regression + warnings-as-errors gate)

```bash
mise exec -- mix test          # whole suite green
mise exec -- mix compile       # clean under warnings_as_errors
```

Confirm `resolve/1`'s existing tests still pass unchanged (FR-009 — the
full-restart path is untouched).

## Integration (opt-in — real worktree/branch)

Covers the branch-reuse and branch-gone edge cases that need a real git tree.

```bash
mise exec -- mix test --include integration
```

Expected:

- **Branch reuse**: after a `resolve/1` freed the worktree (branch kept),
  `resume(id)` recreates the worktree from the existing branch and starts at the
  checkpointed phase — the operator's committed fix is present. (FR-005)
- **Branch gone**: with the feature branch deleted, `resume(id)` surfaces
  `{:error, {:worktree, _}}` (the feature is notified `:failed`) and never starts
  a fresh unrelated branch. (FR-005 edge case, SC-005)

## Manual operator smoke (iex)

```elixir
# after fixing the root cause on the feature branch and committing it:
iex> SpeckitOrchestrator.resume("004-some-feature", prompt: "fixed the float in data-model.md, re-run analyze")
{:ok, #PID<…>}
iex> SpeckitOrchestrator.print_status()   # shows the feature running from its checkpointed phase
```
