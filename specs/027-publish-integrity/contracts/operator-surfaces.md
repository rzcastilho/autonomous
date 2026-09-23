# Contract: Operator surfaces (FR-004, FR-005, FR-010)

## `SpeckitOrchestrator.PublishOutcome.describe/1` (pure)

```elixir
@spec describe(term()) :: String.t() | nil
```

| input | output (single string; `output` verbatim, on its own line) |
|---|---|
| `{:publish_failed, :empty_branch, d}` | `publish_failed :empty_branch — <branch> has no commits beyond <base> (<branch_sha> = <base_sha>)` |
| `{:publish_failed, :push_failed, d}` | `publish_failed :push_failed — git push <remote> <branch>:\n<output>` |
| `{:publish_failed, :pr_failed, d}` | `publish_failed :pr_failed — gh pr create --head <branch> --base <base> (exit <exit>):\n<output>` |
| `{:branch_drift, phase, %{expected: e, observed: o}}` | `branch_drift in :<phase> — expected <e>, HEAD on <o>` (`o` rendered `detached@<sha>` when detached) |
| anything else | `nil` (the caller falls back to its current rendering) |

The text uses only real identifiers (Principle VII): the atoms as typed, branch names, and command names.

## Consumers

| Surface | Today | After |
|---|---|---|
| `Report.format_reason/1` (`print_status/0`, final report line `stopped: …`) | `inspect/1` fallback | `PublishOutcome.describe/1 \|\| inspect/1` |
| `MissionControlLive` parked banner | `inspect(@run_state.stopped_reason)` | describe-or-inspect, same `parked-banner-mono` span |
| `RunDetailLive` run header `stopped at …` | `inspect(@run.stopped_reason)` | describe-or-inspect |
| `RunDetailLive` feature row `reason:` | local `format_reason/1` | describe first, then the existing clauses |
| `RunsLive` row | `inspect(run.stopped_reason)` | describe-or-inspect |

Multi-line output renders inside the existing mono span with `white-space: pre-wrap` supplied by an **existing** console class, or by a class added to `console.css` using existing tokens only. There is no inline style and no new literal, so `design_contract_test.exs` stays green.

## Telemetry

`[:speckit, :publish, :failed]` metadata is `%{feature_id, kind, reason}`, adding `kind`. `Telemetry.attach_default_logger/0` logs `describe/1` of the reason.
