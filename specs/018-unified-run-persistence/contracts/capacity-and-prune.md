# Contract: Capacity Ceiling and Operator Pruning

**Feature**: `018-unified-run-persistence` | **Requirements**: FR-031, FR-031a–e,
SC-014, SC-015

The governing rule: **nothing is ever removed except by an explicit operator
prune.** Refusing to start a new run is how that guarantee is kept, not a
failure mode (FR-031b).

## Capacity — pure policy

```elixir
Store.Capacity.check(%{used_bytes:, capacity_bytes:, headroom_bytes:,
                       reclaimable_bytes:})
  :: :ok
   | {:refuse, %{shortfall_bytes:, used_bytes:, capacity_bytes:,
                 headroom_bytes:, reclaimable_bytes:}}
```

Decision table:

| Condition | Result |
|-----------|--------|
| `used + headroom <= capacity` | `:ok` |
| `used + headroom > capacity` | `{:refuse, …}` with `shortfall_bytes = used + headroom - capacity` |

Pure, no IO, unit-tested with no schema. Measurement is the caller's job
(`Store.Query.capacity/0` — `:mnesia.table_info(:speckit_transcript, :memory)`
plus a `File.stat/1` sum over the store dir; neither reads table contents).

Defaults: `Config.store_capacity_bytes/0` = `1_500_000_000` (kept safely under
the DETS per-table ceiling that `disc_only_copies` inherits);
`Config.store_headroom_bytes/0` = `150_000_000`.

## What a refusal does and does not block (FR-031c, SC-015)

| Operation | Under a capacity refusal |
|-----------|--------------------------|
| `run/1`, `run_spec/2` | **Refused**, with a message naming the shortfall and what pruning would reclaim |
| An already in-flight run | **Untouched** — continues normally |
| `run_history/1`, `run_detail/1`, `transcript/1` | Available |
| `export_run/2` | Available (FR-032c) |
| `prune_preview/1`, `prune/1` | Available — pruning is the operator's way out |
| `resume/2`, `resume_run/1` | Refused on the same basis as `run/1` (a resume starts new phases, which record) |

Refusal message shape:

```
run refused: store capacity headroom exhausted —
  used 1.42 GB of 1.50 GB (headroom 150 MB, short by 68 MB).
  Pruning runs older than <boundary> would reclaim 0.91 GB.
  Nothing has been deleted; run SpeckitOrchestrator.prune_preview(before: …) to see what would go.
```

Hitting the ceiling **mid-run** is not a refusal — it is a write failure, and
therefore drain-and-halt (`contracts/persistence-failure.md`, FR-031d). No row
is ever deleted to make room (FR-031a).

## Prune — pure policy

```elixir
Store.Prune.plan(run_summaries, boundary, protected_run_ids)
  :: %{removable: [%{run_id:, ended_at:, bytes:}],
       retained:  [%{run_id:, reason: :in_flight | :resumable | :after_boundary}],
       bytes_reclaimable: integer}
```

Rules:

1. A run whose `state` is `:in_flight` is **never** removable.
2. A run any of whose features is resumable — a live checkpoint with a
   non-`:done` status — is **never** removable, regardless of boundary
   (FR-031's second clause).
3. Everything else at or before `boundary` is removable.
4. A protected run is reported in `retained` **with its reason** — never
   silently skipped.
5. `bytes_reclaimable` sums each removable run's recorded transcript `bytes`
   plus a fixed per-row estimate for its control rows. Computed from stored
   counts; never by deleting and measuring.

`prune_preview/1` returns the plan and performs nothing (FR-031e).
`prune/1` requires `confirm: true` and executes the plan in **one transaction
per removed run**, deleting every row of that run across all tables — so a
transcript can never be pruned out of step with the phase attempt it belongs to
(FR-035).

## Invariants (SC-014)

- No expiry, rollover, overwrite, downsampling, or truncation happens on its
  own, at any age or volume.
- 0 run records and 0 transcripts are removed without an explicit operator
  prune — asserted by a test that fills the store past the headroom threshold
  and verifies the row count is unchanged and the next run start is refused.
