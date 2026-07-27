# Contract: `SpeckitOrchestrator.AnalyzeRunner` (edge — drives the loop)

The edge module that turns `Remediation.next/2`'s decisions into harness runs.
Not a process: called synchronously from the same supervised `Task`
`FeatureRunner` already runs in, exactly as `ChunkRunner` is for `:implement`.

## 1. Entry point

```elixir
@type opts :: %{
        required(:pid)       => pid(),                 # the FeatureAgent server
        required(:feature)   => Feature.t(),
        required(:worktree)  => Worktree.t() | nil,
        required(:layout)    => Layout.t() | nil,
        required(:timeout)   => timeout(),
        required(:step)      => pos_integer(),         # analyze's pipeline step (5)
        required(:ledger)    => pid() | atom() | nil,
        required(:settings)  => Remediation.Settings.t()
      }

@spec run(opts()) :: struct()   # the `agent` shape FeatureRunner expects
```

`FeatureRunner.run_step/9` gains one clause, mirroring the existing `:implement`
clause:

```elixir
defp run_step(pid, feature, :analyze, step, timeout, ledger, worktree, layout, _chunk_opts) do
  AnalyzeRunner.run(%{pid: pid, feature: feature, worktree: worktree, layout: layout,
                      timeout: timeout, step: step, ledger: ledger, settings: settings})
end
```

Settings are resolved once per feature run from the run's captured
`RunContext` (never from live `Config` — FR-010b).

## 2. Loop

```text
run/1
 ├─ analyze run 1                     (PhaseStep, label per §4)
 ├─ loop:
 │    signals = %{step: :analyze, outcome:, result:, breaker?: Ledger.breaker_tripped?}
 │    case Remediation.next(state, signals)
 │      {:remediate, findings, state'} ─► "auto_remediation.run" signal
 │                                          │
 │                                          ├─ signals = %{step: :remediation, outcome:, breaker?:}
 │                                          └─ Remediation.next ─► analyze run k+1 ─► loop
 │      {:gate, _}          ─► finish/2   (final analyze result governs)
 │      {:gate, {:exhausted, n}, _} ─► finish/2 with exhausted: n
 │      {:halted, :breaker, _}       ─► halt/2
 │      {:failed, :remediation_failed, _} ─► fail/2
```

**Disabled short-circuit** (FR-010, SC-004, SC-007a): when
`settings.enabled? == false`, `run/1` performs exactly one analyze run through
`PhaseStep` with the plain `analyze` label and returns — no `Remediation.next/2`
call, no extra transcript, no telemetry beyond today's `[:speckit, :phase]`
span, no cost beyond the one analyze run. The same short-circuit is what makes
"no added latency" hold for a below-threshold feature (FR-016): the loop's first
`next/2` returns `{:gate, _}` before any second harness call.

## 3. Return shape

`AnalyzeRunner.run/1` returns the agent struct, patched exactly as
`ChunkRunner` patches it, so `FeatureRunner` needs no new vocabulary:

| Terminal | `last_outcome` | `last_signals` | `terminal_reason` |
|---|---|---|---|
| converged / below threshold / disabled | from the **final** analyze run | from the final analyze run (`%{critical?:, high?:}`) | `nil` |
| attempts exhausted | from the final analyze run | final run's signals + `%{remediation: %{attempts: n, limit: m, exhausted?: true}}` | `nil` |
| remediation step failed | `:error` | `%{}` | `{:failed, :remediation_failed}` |
| breaker tripped between steps | `:error` | `%{}` | `{:halted, :breaker}` |

`FeatureRunner`'s existing `chunk_terminal_override/1` is generalized to
`terminal_override/1` (same two clauses, no behaviour change) so both edge
modules share the seam.

**Gate evaluation is unchanged.** `FeatureRunner` still calls
`Pipeline.next(:analyze, last_outcome, last_signals)`; only the *reason* is then
passed through `Remediation.terminal_reason/2` (contracts/remediation.md §4).

## 4. Records (FR-012, FR-012a, research R9)

All written through `Transcripts.write_labelled/6` at the analyze **step number**
— attempts never consume a pipeline step:

| When | Worktree + durable filename |
|---|---|
| loop made ≥1 attempt: k-th analyze run | `NN-analyze-a<k>.md` |
| loop made ≥1 attempt: k-th remediation | `NN-remediation-a<k>.md` |
| always, once, at loop end | `NN-analyze.md` — the **final** analyze run |
| loop made no attempt | `NN-analyze.md` only |

`NN-analyze.md` keeps today's exact name and content shape so
`Recovery.Evidence`, `TranscriptsLive` and the feature drawer keep working
untouched. Durable copies live under the run's `transcript_root`, so a feature
that converges and is later cleaned up as `:done` still has its full attempt
history (FR-012a).

Each remediation transcript's body carries the attempt header rendered by
`Transcripts.render/2` plus the instruction and the step's final text — i.e. the
triggering findings, the instruction issued, the outcome and the cost are all
recoverable from one file (FR-012).

## 5. Cost and the breaker (FR-009, FR-009b, SC-006, SC-008)

- Each analyze re-run charges `Cost.for_phase(:analyze, result)` — unchanged
  path, unchanged estimate.
- Each remediation attempt charges `Cost.for_phase(:auto_remediation, result)`,
  a **new** `:cost_estimates` key so an attempt with no reported actual is never
  free (SC-008).
- Both go through `Ledger.record/3` exactly as every other step does. The loop
  gets no budget exemption and creates no reservation of its own (FR-009).
- `Ledger.breaker_tripped?/1` is consulted **between** steps only. The in-flight
  step always finishes and is always accounted; nothing new starts after a trip
  (Principle IV, drain-don't-kill).

## 6. `SpeckitOrchestrator.PhaseStep` (extracted, research R8)

`FeatureRunner`'s private `run_phase/7` and `run_phase_with_retry/8` move here
verbatim plus a `:label` option:

```elixir
@spec run(pid(), Feature.t(), Pipeline.phase(), keyword()) :: struct()
# opts: :step, :timeout, :worktree, :layout, :label (default: phase name),
#       :retries (default Config.phase_max_retries/0), :span_meta (extra keys)
```

Behaviour is unchanged for existing callers: same `[:speckit, :phase]` span,
same meta (`%{feature_id, phase, model, step}`), same transient-retry policy
(`PhaseResult.transient?/1`), same `Transcripts` write, same `Logger.info` line.
`FeatureRunner` delegates; the existing `feature_runner_test.exs` suite is the
regression proof.

`AnalyzeRunner` calls it with `label: "analyze-a#{k}"` and
`span_meta: %{attempt: k, limit: n}` — and, when the loop is disabled, with no
label and no extra meta at all, so the emitted event is byte-identical to today
(FR-010).

## 7. The remediation step itself

- Signal `"auto_remediation.run"` → `Actions.RunAutoRemediation`, data
  `%{prompt: String.t(), model: String.t(), attempt: pos_integer()}`.
- Request built by the existing `PhaseRequest.build_remediation/3` with
  `cwd: <worktree path>`, `layout:`, `prompt:` — so it inherits
  `permission_mode: :accept_edits`, the `Read Write Edit Bash Grep Glob` tool
  set, and worktree containment unchanged (FR-014). No new request builder, no
  new permission.
- Fresh session per attempt (no `session_id` resume), same as every phase.
- The action folds `last_result` / `last_outcome` / `session_id` / `cost_total`
  and a `%{phase: :auto_remediation, attempt: k, outcome:, cost:}` history entry
  back into agent state. It decides **no** control flow — `AnalyzeRunner` owns
  that (mirrors `RunRemediation`'s division of labour).
- 013's operator pre-phase remediation path (`"remediation.run"` /
  `Actions.RunRemediation`) is untouched and still runs first when a resume
  supplies one; the loop then applies to the analyze run that follows (spec Edge
  Cases).

## 8. Concurrency

One loop state per feature run, held in the runner's own `Task` stack frame.
Two features remediating concurrently share nothing but the `Ledger` — whose
serialization is already its job. No new process, no new supervision-tree child.
