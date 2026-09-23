# Contract: `SpeckitOrchestrator.Workers`

Process-layer module (not pure core). Owns `WorkerRegistry` membership and the
drain-request table. Started under the application supervisor **before**
`RunnerSup`, so no worker can spawn without it.

## `spawn(run_key, feature_id, fun) :: {:ok, pid()} | {:error, term()}`

Replaces the five direct `Task.Supervisor.start_child(RunnerSup, …)` call
sites. Starts a `RunnerSup` child whose **first** act, before calling `fun`, is
to register `{repo_id, %{feature_id, run_id, deadline_at: nil}}`.
`run_key == nil` ⇒ same child, no registration.

- MUST NOT link the child to the caller or the Coordinator (FR-009).
- Registration precedes worktree creation and spec-number allocation.

## `session_started(deadline_ms) :: :ok`

Called by the worker (owner-only) immediately before each session-driving
`AgentServer.call`. Sets `deadline_at = now + deadline_ms`. No-op when the
caller is not registered.

## `drain_requested?() :: boolean()`

The boundary predicate. `true` iff a drain request exists for `self()`. Pure
read, never consumes the latch; safe to call from every boundary site.

## `in_flight(repo_id) :: [entry]`

Read-only listing (FR-013). `entry = %{pid, feature_id, run_id, deadline_at}`.
Other repositories' workers never appear (FR-007).

## `drain(repo_id) :: :ok | {:error, {:drain_timeout, [%{feature_id, run_id}]}}`

1. `entries = in_flight(repo_id)`; `[]` ⇒ return `:ok` **immediately** — no
   wait, no telemetry beyond none (FR-012, SC-005).
2. For each entry: monitor pid, insert drain request, compute
   `Bound.wait_ms/3` from its `deadline_at`.
3. Wait for every `:DOWN` up to the max bound.
4. Delete every request inserted in step 2 (whether or not the worker exited).
5. All down ⇒ `:ok`. Otherwise ⇒ `{:error, {:drain_timeout, stuck}}` naming
   each still-alive worker's feature and run (FR-004).

MUST NOT call `Process.exit/2` on a worker, nor stop its agent, at any point —
including on timeout (spec Assumptions: an outside kill orphans the CLI). A
worker already dead at step 2 yields an immediate `:DOWN` (no delay).

Emits `[:speckit, :drain, :start | :stop]` with `%{repo_id, feature_ids}` and
`:stop` metadata `%{result: :ok | :timeout}`.

## Worker side — boundary obligations

Every site that consults `Ledger.breaker_tripped?/1` before starting a new
session MUST also consult `drain_requested?/0`, and MUST do so only after the
preceding session's attempt, checkpoint, and transcript are recorded (FR-003,
FR-008). On `true` the worker takes the **drained exit** (data-model.md):

| MUST | MUST NOT |
|------|----------|
| finalize the agent; commit and keep the worktree; emit `[:speckit, :feature, :drained]`; stop the agent; exit | write a feature terminal status; open an escalation; emit `[:speckit, :feature, :terminal]`; `notify` the Coordinator |
