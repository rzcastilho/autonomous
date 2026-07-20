# Data Model: FeatureRunner Resume Entry Point

No persistent storage. "Entities" here are in-memory: `run/2` options and the
agent state fields that carry them. Types are Elixir terms.

## `run/2` options (new)

| Option          | Type                  | Default             | Meaning |
|-----------------|-----------------------|---------------------|---------|
| `:start_phase`  | `Pipeline.phase()`    | `Pipeline.first()`  | Phase the pipeline loop begins at. Existing opts (`:worktree`, `:ledger`, `:notify`, `:phase_timeout`, `:agent_id`) unchanged. |
| `:resume_prompt`| `String.t()` \| `nil` | `nil`               | Optional context carried into agent state for later prompt injection (feature 004+). Not consumed by this feature. |

## `FeatureAgent` state fields (new)

Added to the agent schema (`feature_agent.ex`), both nullable so fresh runs are
unaffected:

| Field           | Type            | Default | Mutation | Meaning |
|-----------------|-----------------|---------|----------|---------|
| `resume_phase`  | `:atom`         | `nil`   | Set once at init; **never** mutated by the loop. | The phase the run was started/resumed at — the fixed anchor. |
| `resume_prompt` | `:string`       | `nil`   | Set once at init; read-only. | Optional resume context passed through from `run/2`. |

Existing field interaction:

- `phase` (`:atom`, default `nil`) — already present; seeded to `params.phase`
  and **advanced** each phase by the loop / `RunFeaturePhase`. Distinct from
  `resume_phase` (which stays fixed). At init, `phase == resume_phase`.

## `InitFeature` action schema (extended)

`actions/init_feature.ex` — routed by `"feature.init"`:

| Param           | Type    | Required | Default            | Seeds state field |
|-----------------|---------|----------|--------------------|-------------------|
| `feature`       | `:any`  | yes      | —                  | `feature`         |
| `worktree`      | `:any`  | no       | `nil`              | `worktree`        |
| `ledger`        | `:any`  | no       | `nil`              | `ledger`          |
| `phase`         | `:atom` | no       | `Pipeline.first()` | `phase` **and** `resume_phase` |
| `resume_prompt` | `:string`| no      | `nil`              | `resume_prompt`   |

Seed rule: `phase: params.phase`, `resume_phase: params.phase` (same value at
init, diverge thereafter), `resume_prompt: params.resume_prompt`.

## State transitions

```text
run/2(opts)
  start_phase = opts[:start_phase] || Pipeline.first()
  step        = Pipeline.step_of(start_phase)          # 1-based index in phases/0
  → "feature.init" %{phase: start_phase, resume_prompt: …}
       InitFeature seeds phase = resume_phase = start_phase
  → loop(pid, feature, start_phase, step, …)
       each {:cont, next}: phase advances (next, step+1); resume_phase stays fixed
       terminal: finalize as today
```

## Validation rules

- `start_phase` MUST be a member of `Pipeline.phases/0`. Not enforced by this
  feature — caller's responsibility (see research Decision 2). `step_of/1` is
  correct for every member; behavior for a non-member is out of scope.
- No new invariants on the breaker/ledger — unaffected.
