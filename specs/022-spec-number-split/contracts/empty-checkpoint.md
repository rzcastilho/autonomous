# Contract: Empty-checkpoint net

Covers FR-012 – FR-015 (net two). A phase whose contract is to produce a named
file, that starts with that file absent and commits nothing at its boundary,
fails at that phase.

## 1. Pure surface — `SpeckitOrchestrator.Checkpoint`

```elixir
@armed_phases [:specify, :plan, :tasks]

@type commit_result :: :ok | :noop | {:error, term()}

@spec armed?(Pipeline.phase()) :: boolean()
@spec verdict(Pipeline.phase(), boolean(), commit_result()) ::
        :advance | {:failed, {:empty_checkpoint, Pipeline.phase()}}
```

Decision table — every cell, no defaults:

| phase | absent at start? | commit | verdict |
|---|---|---|---|
| `:specify` `:plan` `:tasks` | `true` | `:noop` | `{:failed, {:empty_checkpoint, phase}}` |
| `:specify` `:plan` `:tasks` | `true` | `:ok` | `:advance` |
| `:specify` `:plan` `:tasks` | `true` | `{:error, _}` | `:advance` |
| `:specify` `:plan` `:tasks` | `false` | any | `:advance` |
| `:clarify` `:analyze` `:implement` `:converge` | any | any | `:advance` |

Rationale for row 3: a git failure is a broken probe, not evidence the phase
wrote nothing — the same conservative direction `implementation_changes?/2`
already takes.

Rationale for row 4: FR-014a. A resumed phase re-running over output that
already existed may legitimately confirm it and write nothing; its output stays
judged by the artifact gate, which tests substance (`ArtifactSubstance`), not
mere presence.

## 2. Arming signal — `RunFeaturePhase`

```elixir
@checkpoint_artifacts %{specify: "spec.md", plan: "plan.md", tasks: "tasks.md"}
```

Probed **before** `Jido.Harness.run_request/3` is issued, and merged into the
phase's `last_signals`:

```elixir
artifact_absent_at_start? =
  is_nil(SpecDir.file(worktree_path(state.worktree), state.feature, leaf))
```

- Emitted only for the three armed phases, and only when there is a worktree.
  Absent elsewhere; `Checkpoint.verdict/3` reads a missing key as `false`, so an
  unarmed or worktree-less run is byte-identical to today.
- `:specify` is armed here and is **NOT** added to the artifact gate's
  `@phase_artifacts` — this feature adds no new artifact gate (research R6).
- Independent of the artifact gate by construction: it is probed at phase
  **start**, from a different map, and a passing gate cannot suppress it
  (FR-014).

## 3. Boundary integration — `FeatureRunner.loop/12`

The `{:cont, next}` branch is reordered so one code path produces both outcomes
(research R7):

```
1. commit_result = worktree && Worktree.commit(worktree, "speckit: <id> checkpoint after <phase>")
2. verdict       = Checkpoint.verdict(phase, gate_sigs[:artifact_absent_at_start?] || false, commit_result)
3. decorated'    = case verdict do
                     :advance          -> {:cont, next}
                     {:failed, reason} -> {:failed, reason}
                   end
4. record_attempt(..., checkpoint_for(decorated', phase, st), ...)
5. case decorated' do
     {:cont, next}     -> breaker/persistence drain checks, then recurse
     {:failed, reason} -> {:failed, reason, agent}
   end
```

Consequences:

- `record_attempt/9` now runs **after** the commit for a continuing transition;
  it still runs before recursing, so the "a crash mid-next-phase still finds the
  completed phase's record" guarantee holds.
- A failed verdict leaves the `{:failed, reason}` checkpoint shape
  (`phase:` = the failing phase, `status: :failed`, `reason:`), so a resume
  restarts at the phase that failed rather than the one after it.
- The commit is unchanged for every non-armed phase and for every armed phase
  that wrote something — including the `:noop` case for a resumed phase whose
  artifact already existed.
- No retry. `PhaseStep` retries transient failures, outstanding work, and
  unfilled templates; an empty checkpoint is a boundary verdict reached after
  the phase is over and is terminal for the feature (US2 scenario 1: "no later
  phase is started").

## 4. Reason shapes (FR-013)

| Reason | Meaning | Producer |
|---|---|---|
| `{:empty_checkpoint, phase}` | the phase committed no change and its artifact was absent when it started | `Checkpoint.verdict/3` |
| `{:missing_artifact, phase, artifact}` | the phase's named artifact is absent or unfilled after it ran | `Pipeline.next/3` |

Distinct constructors, distinct arity, distinct rendering. Operator-facing text:

- `{:empty_checkpoint, :tasks}` → `tasks committed no change`
- `{:missing_artifact, :tasks, "tasks.md"}` → existing text, unchanged.

Both reach the run report, the console, and the `feature_run.terminal_reason`
column through the paths they already use — the feature reaches `:failed`, an
existing terminal status. No new lifecycle status is introduced.

## 5. Independence (SC-007)

The two nets share no code and no signal:

- Net one lives in `SpecDir`'s candidate rules.
- Net two lives in `Checkpoint` + one probe in `RunFeaturePhase` + the boundary
  ordering in `FeatureRunner`.

Each is exercised alone in the test suite with the other's behaviour reverted
(quickstart §5), and each catches the observed failure at the phase that caused
it.
