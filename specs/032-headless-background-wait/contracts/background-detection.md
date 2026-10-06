# Contract: Background-Wait Detection (US1, FR-001–FR-005)

## 1. `Autonomous.BackgroundMarker` (CLI-contract boundary)

The only module that knows the CLI's wording. Pinned to `claude` 2.1.287 and
recorded in `docs/harness-contract.md`.

```elixir
@spec parse(String.t()) :: {:ok, %{mode: mode, task_id: String.t() | nil,
                                    output_path: String.t() | nil}} | :none
@spec explicit_call?(map()) :: boolean()   # input["run_in_background"] == true
```

| mode | must match (regex sketch, case-sensitive) |
|---|---|
| `:timeout` | `Command did not complete within its \d+s timeout and was moved to the background \(ID: (?<id>[^)\s]+)\)` |
| `:message` | `Command was moved to the background \(ID: (?<id>[^)\s]+)\)` |
| `:manual` | `Command was manually backgrounded by user with ID: (?<id>\S+?)\.?(\s\|$)` |
| `:explicit` | `Command running in background with ID: (?<id>\S+?)\.?(\s\|$)` |
| path (any mode) | `Output is being written to: (?<path>\S+?)\.?(\s\|$)` |

Result `output` may be a string or a list of content blocks. It is flattened
to text before matching. Non-text output → `:none`.

## 2. `PhaseResult` additions (pure)

```elixir
@spec backgrounded_commands(t() | nil) :: [BackgroundedCommand.t()]
@spec stranded_background(t() | nil) :: [String.t()]   # [] unless status == :ok
```

Required behaviour (test table):

| # | event stream (after a successful `:session_completed`) | `stranded_background/1` |
|---|---|---|
| 1 | Bash call → `:timeout` marker (id `b1`, path `/tmp/x.out`) → nothing else | `["<cmd>"]` |
| 2 | as 1, then `Read` call with `file_path: "/tmp/x.out"` | `[]` |
| 3 | as 1, then any call/result whose text contains `b1` | `[]` |
| 4 | as 1, then unrelated `Bash`/`Edit` calls | `["<cmd>"]` |
| 5 | Bash call `run_in_background: true` → `:explicit` marker, never read | `["<cmd>"]` |
| 6 | Bash call `run_in_background: true` → result with no marker | `["<cmd>"]` (no identifiers) |
| 7 | marker result whose own text contains its id (always) | does not resolve itself |
| 8 | any of the above but `status: :error` / `:incomplete` | `[]` (FR-004) |
| 9 | every existing `phase_result_test` fixture without backgrounding | `[]` (SC-002) |
| 10 | SC-001 fixture (synthetic replay of fretboard-master 014 `3e935ca9`) | non-empty |

## 3. Gate placement per site

| site | order | suppression |
|---|---|---|
| `RunFeaturePhase` (non-implement phases) | branch drift → **background** → outstanding_work? → phase gates | `:plan`/`:tasks` with satisfied artifact gate |
| `RunFeaturePhase` (implement, any scope) | branch drift → **background** → (existing, still suppressed) outstanding_work? → deferred gate | **none** |
| `RunAutoRemediation`, `RunRemediation` | branch drift → **background** → status | none |

On a hit, every site returns
`{:error, %{outstanding_work?: true, backgrounded: cmds}}` and logs at
`:warning`:
`phase <p> ended waiting on backgrounded command(s): <cmd1>; <cmd2> — treating as incomplete`.

## 4. Retry

- `PhaseStep.retry_reason/1`: when `signals[:backgrounded]` is non-empty →
  `"ended waiting on a backgrounded command"`. Branch drift keeps first
  place (never retried). Uses the existing `retries` budget
  (`Config.phase_max_retries/0`, default 1). Both gates firing is one retry.
- The retry's `"phase.run"` data carries `background_retry: cmds`.
  `RunFeaturePhase` forwards it to `PhaseRequest.build/3`
  (contracts/prompt-rules.md §2). A retry for any other reason carries no
  such key, so the prompt stays byte-identical (FR-002a).
- `Chunking.next/2` new row **B** (after row 0, before row 2):

| condition | decision |
|---|---|
| `signals.backgrounded != []` and `not state.background_retried?` and `sessions_used < ceiling` | `{:dispatch, same_scope, %{state \| background_retried?: true, attempt: attempt + 1, sessions_used: sessions_used + 1}}` |
| `signals.backgrounded != []` and `state.background_retried?` | `{:failed, {:backgrounded_command, current_ref(state), cmds}, state}` |
| `signals.backgrounded != []` and ceiling reached | `{:failed, {:session_ceiling, ceiling}, state}` |

  `ChunkRunner` re-dispatches with `background_retry: cmds`.
  `background_retried?` resets on cursor advance or when the sweep starts.
  The boundary commit and the per-chunk store row are unchanged.

## 5. Failure and rendering

- `Pipeline.next(phase, :error, %{backgrounded: [_ | _] = cmds})` →
  `{:failed, {:backgrounded_command, phase, cmds}}`, as a clause **ahead of**
  the `outstanding_work?: true` clause.
- `Report.format_reason({:backgrounded_command, where, [c | rest]})` →
  `"#{where_label} ended waiting on backgrounded command: #{trunc(c, 120)}"`
  plus `" (+#{length(rest)} more)"` when `rest != []`. `where_label` is the
  phase atom, or the task-phase label for a chunk ref.
- No new lifecycle status. The feature ends `:failed`, and its worktree is
  kept (Principle V).
