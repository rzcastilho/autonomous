# Contract: `SpeckitOrchestrator.resume/2`

The operator entry point that restarts one halted/escalated feature at its
checkpointed phase. CLI/facade contract (this project exposes an `iex` operator
surface, not an HTTP API).

## Signature

```elixir
@spec resume(feature_id :: String.t(), opts :: keyword()) ::
        GenServer.on_start()
        | {:error, :no_checkpoint}
        | {:error, :corrupt_checkpoint}
        | {:error, {:unknown_feature, String.t()}}
        | {:error, {:unknown_phase, atom()}}
        | {:error, {:worktree, term()}}
def resume(feature_id, opts \\ [])
```

## Options

| Opt | Type | Default | Meaning |
|---|---|---|---|
| `:prompt` | `String.t()` \| `nil` | `nil` | Operator guidance injected into the resumed phase (`resume_prompt`). `nil` ⇒ no note, no placeholder. |
| `:from` | `atom()` | checkpoint `last_phase` | Override the start phase. Takes precedence over the checkpoint. |
| `:features` | `[Feature.t()]` | `Backlog.load!/…` | Backlog override (tests). |
| `:runner` | `(Feature.t(), notify -> :ok)` | injected resume runner | Runner override (tests). When supplied by the caller, it wins — the resume wrapper is NOT injected. |
| `:max_concurrency`, `:owner`, … | — | as `run/1` | Passed through to `run/1` unchanged (FR-008). |

## Success

- **Returns** the Coordinator `on_start` tuple `{:ok, pid}` (same shape as
  `run/1`), having started a one-feature wave whose runner begins at
  `start_phase` and carries `:prompt` through as `resume_prompt`.
- `start_phase = opts[:from] || (checkpoint.last_phase parsed to a phase atom)`.

## Errors (each starts NO run — Principle II / SC-005)

| Result | When |
|---|---|
| `{:error, {:unknown_feature, id}}` | `id` matches no feature in the backlog. Matches `resolve/1`. |
| `{:error, :no_checkpoint}` | No checkpoint file for `id`. |
| `{:error, :corrupt_checkpoint}` | Checkpoint file exists but is unreadable/undecodable (distinct from no-checkpoint). |
| `{:error, {:unknown_phase, phase}}` | `:from` override — or the stored checkpoint phase — is not in `Pipeline.phases/0`. |
| `{:error, {:worktree, reason}}` | The feature branch is gone so the worktree cannot be recreated from it; surfaced via the runner `notify(:failed, {:worktree, reason})`. Resume never starts a fresh unrelated branch. |

## Invariants

1. **No re-execution of completed phases** — the runner starts at
   `start_phase`, never `Pipeline.first()` (unless that *is* the checkpoint/override). (SC-002)
2. **Distinct, non-collapsing failures** — no error is folded into another; none
   silently falls back to phase one or a fresh branch. (SC-005)
3. **Guidance fidelity** — when `:prompt` is supplied it reaches the resumed
   phase unchanged; when absent the phase runs with no note. (SC-003, FR-004)
4. **Single-feature scope** — exactly the identified feature is affected; no
   other backlog feature is released. (FR-010)
5. **`resolve/1` unchanged** — the full-restart path remains available and
   distinct. (FR-009)

## Test scenarios (map to acceptance)

| # | Setup | Call | Expect |
|---|---|---|---|
| T1 | fixture checkpoint `last_phase: analyze`, fake runner | `resume(id)` | runner invoked with `start_phase: :analyze` (US1 AS1) |
| T2 | no checkpoint | `resume(id)` | `{:error, :no_checkpoint}`, runner never invoked (US1 AS2) |
| T3 | unknown id | `resume("999-nope")` | `{:error, {:unknown_feature, "999-nope"}}` (US1 AS3) |
| T4 | checkpoint `analyze`, `:prompt` set, fake runner | `resume(id, prompt: "fixed float")` | resumed phase receives that prompt (US2 AS1, SC-003) |
| T5 | checkpoint `analyze`, no `:prompt` | `resume(id)` | runner runs with `resume_prompt: nil`, no error (US2 AS2) |
| T6 | checkpoint `analyze`, `:from` override | `resume(id, from: :plan)` | runner `start_phase: :plan` (US3 AS1) |
| T7 | checkpoint `analyze`, `:from` bogus | `resume(id, from: :nope)` | `{:error, {:unknown_phase, :nope}}`, no run |
| T8 | corrupt checkpoint file | `resume(id)` | `{:error, :corrupt_checkpoint}`, no run |
| T9 | branch gone (real worktree path) | `resume(id)` | feature notified `:failed` with `{:worktree, _}`; no fresh branch (integration) |
