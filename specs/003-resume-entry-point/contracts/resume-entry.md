# Contract: Resume Entry Point

Internal Elixir function contracts (this is a library; the "interface" is the
public function surface of `Pipeline` and `FeatureRunner`).

## `SpeckitOrchestrator.Pipeline.step_of/1`

```elixir
@spec step_of(phase()) :: pos_integer()
def step_of(phase)
```

- **Input**: a phase atom that is a member of `phases/0`.
- **Output**: the 1-based index of `phase` in `phases/0`.
- **Table** (the whole contract, exhaustively):

  | phase       | step_of |
  |-------------|---------|
  | `:specify`  | 1 |
  | `:clarify`  | 2 |
  | `:plan`     | 3 |
  | `:tasks`    | 4 |
  | `:analyze`  | 5 |
  | `:implement`| 6 |
  | `:converge` | 7 |

- **Purity**: side-effect free (Principle I). No CLI/agent/worktree access.
- **Undefined**: behavior for a phase not in `phases/0` (including `:done`) is
  out of scope; caller guarantees membership.
- **Property**: `step_of(first()) == 1`; `step_of(List.last(phases())) == length(phases())`.

## `SpeckitOrchestrator.FeatureRunner.run/2` (extended)

```elixir
@spec run(Feature.t(), keyword()) :: result() | {:error, term()}
```

New recognized opts (all others unchanged):

- `:start_phase` (`Pipeline.phase()`, default `Pipeline.first()`) — loop begins here.
- `:resume_prompt` (`String.t() | nil`, default `nil`) — carried into agent state.

Behavioral contract:

1. With **no** `:start_phase` → begins at `Pipeline.first()`, step `1`. Byte-for-byte
   the same observable behavior as before this feature (no regression).
2. With `:start_phase == :plan` → begins at `:plan`, step `3`; runs to a terminal
   state; transcripts written as `NN-<phase>.md` where `NN` starts at `3`.
3. `:resume_prompt` value appears in the agent's `resume_prompt` state field after
   `feature.init`; it does not alter any phase request in this feature.
4. `resume_phase` state field equals `:start_phase` at init and remains fixed as
   the loop advances `phase`.

## `SpeckitOrchestrator.Actions.InitFeature` (extended schema)

Adds `phase: [type: :atom, default: Pipeline.first()]` and
`resume_prompt: [type: :string, default: nil]`. Seeds `phase`, `resume_phase`
(both = `params.phase`), and `resume_prompt`. `feature`/`worktree`/`ledger`
contract unchanged.

## Backward-compatibility guarantee

Every existing caller of `run/2` and every existing `"feature.init"` payload
continues to work: the new opts/params default to the pre-feature values, and
the new agent fields default to `nil`. No existing test should require changes to
keep passing (new tests are additive).
