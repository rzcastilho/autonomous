# Contract: facade `resume_run/1`, `resumable_run/0`, and `Coordinator` `:statuses` seam

## `resumable_run/0` — detect & report (FR-008, SC-006)

```elixir
@spec resumable_run() ::
        {:ok, %{features: [...], statuses: %{...}, spend: number(), context: map()}}
        | {:error, :no_manifest}
        | {:error, :corrupt_manifest}
        | :none
```

- Reads `RunManifest.read/0`, classifies via `RunManifest.resumable?/0`.
- Returns a summary of the resumable run when one exists, `:none` when the
  manifest holds only terminal/diverted features, or a loud error on a
  missing/corrupt manifest.
- **Starts no work.** Safe to call on boot to report a resumable run.

## `resume_run/1` — reconstruct & continue (FR-006, FR-007)

```elixir
@spec resume_run(keyword()) ::
        GenServer.on_start()
        | {:error, :no_manifest}
        | {:error, :corrupt_manifest}
        | {:error, {:active_run, pid()}}
```

Steps (each failure is loud and starts nothing — Principle II):

1. **Guard active run** (FR-017, US2 s4): if the named `Coordinator` is alive with
   `finished? == false`, return `{:error, {:active_run, pid}}` unless `opts[:force]`
   is explicitly set. Never clobber a live run silently.
2. **Read manifest**: `RunManifest.read/0`; `:no_manifest`/`:corrupt` → loud error.
3. **Reconstruct**: `RunManifest.reconstruct/1` → `{features, statuses}` (terminal
   kept; `:running`/`:pending` → `:pending`).
4. **Restore spend** (FR-012): `Ledger.restore(Ledger, manifest.spend)`.
5. **Reapply context** (FR-007): merge the manifest `context` under the existing
   `RunContext.merge/2` precedence (explicit opt > recorded > live Config), and
   thread it into every runner call.
6. **Start Coordinator** with the reconstructed `:statuses` (new init option) and a
   **resume-aware runner** (below). `Release` then releases only `:pending`
   features whose prereqs are `:done`, in DAG order under the recorded cap.

### Resume-aware runner (dispatch per feature)

For each released feature:
- **Has a checkpoint** (`Checkpoint.read/1` → `{:ok, _}`): run the feature via the
  existing `resume/2` machinery — locate/recreate worktree from the branch,
  `Worktree.restore/1`, `start_phase:` = phase after `last_phase`, reapply context,
  carry to terminal. A missing branch/worktree → `notify(id, :failed, {:worktree,
  :branch_missing})` (steer to restart, US1 s4) — does not crash the run.
- **No checkpoint** (`:no_checkpoint`): a `:pending` feature never started — run it
  fresh from `Pipeline.first()` (the normal runner path).
- Under the PR workflow (`pr_workflow?` from the reapplied context), route through
  the stacked executor path so cap-1 sequencing/preflight/PR-on-`:done` are
  preserved (as `resume/2` already does).

## `Coordinator` `:statuses` init option (new)

```elixir
# init/1: currently statuses := Map.new(features, &{&1.id, :pending})
# new:
statuses: Keyword.get(opts, :statuses, Map.new(features, &{&1.id, :pending}))
```

- When supplied, seeds the run with reconstructed statuses so `:done` features are
  **not** re-run (SC-002) and `:pending` features release in DAG order.
- Default unchanged (all `:pending`) so `run/1` behavior is identical.

## `Coordinator` manifest seam (new)

- New init option `:manifest` (default `RunManifest`; tests inject a fake).
- The `Coordinator` calls `manifest.write/1` on `init`, `spawn_feature`, and
  `{:finished}`, passing `features`, current `statuses`, `context`, and
  `Ledger.spent/1`. Best-effort; a manifest write never affects wave logic
  (Principle I — the seam keeps the scheduler unit-testable without disk).

## `run/1` manifest lifecycle (new)

- At run start, `run/1` calls `RunManifest.clear/0` then lets the `Coordinator`
  write the fresh manifest — superseding any prior run (single-slot, FR-005).

## Human-gate safety (FR-015, SC-004)

- A feature that was `:escalated`/`:halted` at crash is reconstructed with that
  terminal status **kept** — `Release` never releases a terminal feature, so
  `resume_run/1` never auto-passes the gate. Its `resolve/1` path is unchanged.

## Test contract

- Mixed-state manifest (done/running/pending) → `resume_run/1` re-runs neither the
  done nor the diverted features; the running feature resumes at its next phase;
  pending features release in prereq order. (fakes for runner/manifest/ledger)
- No manifest → `{:error, :no_manifest}`, no Coordinator started.
- Active unfinished run present → `{:error, {:active_run, pid}}` without `:force`.
- Manifest `spend` at budget → after restore, breaker tripped, zero features
  released (drain).
