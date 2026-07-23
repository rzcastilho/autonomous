# Contract: `Ledger.restore/2` (extension)

New function on `SpeckitOrchestrator.Ledger` to restore committed spend on resume
(FR-012), without disturbing the reservation invariant (FR-013).

## `restore/2`

```elixir
@spec restore(GenServer.server(), number()) :: number()
def restore(server \\ __MODULE__, recorded) when is_number(recorded) and recorded >= 0
```

- Sets `committed = max(committed, recorded)` and returns the new committed total.
- **Idempotent** and **monotonic**: never lowers an already-higher live committed
  (safe if the Ledger already advanced, or if `restore/2` is called twice).
- Does **not** touch `reservations` or `budget`.

## Server change

`handle_call({:restore, recorded}, _from, state)`:

```elixir
committed = max(state.committed, recorded)
{:reply, committed, %{state | committed: committed}}
```

## Interaction with the breaker (FR-013 / SC-003)

- After `restore/2`, `breaker_tripped?/1` reflects the restored figure
  immediately: if `restored >= budget`, the breaker is tripped and the resumed
  `Coordinator`/`Release` release nothing (drain, not kill).
- The invariant `committed < budget + max_single_reservation` continues to hold:
  `restore/2` only raises `committed` to a value the pre-crash run had already
  reached under that same invariant.

## Why not reuse `record/3`

`record(server, nil, amount)` **adds** `amount` to committed — correct only while
the app Ledger starts at 0. A resume when committed is already non-zero would
double-count. `restore/2`'s `max` semantics are set-not-add, so it is correct
regardless of the live Ledger's state.

## Test contract

- Fresh Ledger (committed 0), `restore(L, 5.0)` → `spent(L) == 5.0`.
- `restore(L, 3.0)` after committed is 5.0 → stays `5.0` (never lowers).
- `restore(L, budget)` → `breaker_tripped?(L) == true`; a subsequent `reserve/2`
  returns `{:error, :budget_exceeded}`.
