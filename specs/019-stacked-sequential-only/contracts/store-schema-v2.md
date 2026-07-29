# Contract: Store schema v2 and the persistence reset

**Feature**: `019-stacked-sequential-only`

Feature 018's Mnesia store gains a run state, loses a feature field, and bumps
its schema version. FR-022 makes this a **clean break**: no compatibility path
is built, because persistence is reset as part of shipping the change.

---

## 1. Version bump and the refusal migration

```elixir
Store.Migrations.current_version()  # 1 -> 2
```

Version 2 is registered in the same ordered migration list every other migration
lives in, but its function **refuses** instead of transforming:

```elixir
{2, "019 clean break — pre-019 records are not readable",
 fn -> {:error, {:incompatible_record, 1}} end}
```

**Boot behaviour**

| Recorded version | Result |
|---|---|
| absent (fresh directory) | schema created at v2, run number one starts (SC-006) |
| `2` | normal start |
| `1` | **startup aborts**, naming the incompatibility (FR-023) |
| `> 2` | startup aborts (unchanged — newer-than-known already fails loud) |

The abort message names the retired schema and the remedy — remove
`Config.store_dir/0` — documented in `docs/runbook.md`. The system never deletes
the directory itself: silently dropping recorded state is forbidden by the
constitution's persistence rules.

**Why a refusal rather than a transform**: FR-022 forbids a compatibility path,
and the reset guarantees no v1 record exists — a real `transform_table` migration
would be dead code by construction. Registering the refusal as a migration keeps
schema evolution "explicit and versioned" as the constitution requires, while
producing exactly the loud refusal FR-023 asks for.

---

## 2. `speckit_run`

| Attribute | v1 | v2 |
|---|---|---|
| `state` | `:in_flight \| :completed \| :superseded` | `:in_flight \| :parked \| :completed \| :superseded` |
| `outcome` | `:all_done \| :escalated \| :halted \| :failed \| :mixed \| nil` | + `:ended_by_operator` |
| `stopped_by` | — | `String.t() \| nil` — feature that broke the chain |
| `stopped_reason` | — | `term() \| nil` — why it broke |
| everything else | | unchanged |

### Writer operations

```elixir
@spec park_run(run_key, %{stopped_by: String.t(), status: atom(), reason: term()}) ::
        :ok | {:error, term()}
@spec continue_run(run_key) :: :ok | {:error, :not_parked} | {:error, term()}
@spec end_run(run_key, keyword()) :: :ok | {:error, :not_parked} | {:error, term()}
```

All three are single transactions. `end_run/2` writes every still-`:pending`
feature as `:never_started` in the same transaction that flips the run state, so
a closed-out record is never momentarily self-inconsistent.

### `open_run/2` guard

`supersede_in_flight!/2` gains a parked check **before** any supersession:

```elixir
case Query.parked_run(repo_id) do
  nil -> supersede_in_flight!(repo_id, new_run_id)
  %{run_id: id} -> Mnesia.abort({:parked_run, id})
end
```

Aborting inside the transaction is what makes SC-009's "100% of attempts
refused" race-free rather than best-effort.

### Query addition

```elixir
@spec parked_run(String.t()) :: map() | nil
```

Mirrors the existing `in_flight_run/1`.

---

## 3. `speckit_feature`

| Attribute | v1 | v2 |
|---|---|---|
| `prereqs` | `[binary()]` | **removed** |
| `number` | — | `pos_integer()` — ordering key |
| `group` | — | `:backlog \| :ad_hoc` |
| `created_at` | — | `DateTime.t() \| nil` |
| `status` | `… \| :blocked \| :ended_by_supersession` | `:blocked` **removed**, `:never_started` **added** |
| everything else | | unchanged |

---

## 4. Unchanged tables

`speckit_meta`, `speckit_repo`, `speckit_run_settings`, `speckit_settings_amendment`,
`speckit_phase_attempt`, `speckit_checkpoint`, `speckit_escalation`,
`speckit_remediation_attempt`, `speckit_cost_entry`, `speckit_transcript` — no
attribute changes.

`speckit_run_settings` stores `RunContext.to_map/1`, which drops from ten keys to
eight. The value is an opaque map, so this is a value change, not a schema
change.

Storage types are unchanged: `disc_copies` for control tables,
`disc_only_copies` for `speckit_transcript`.

---

## 5. What is deliberately absent

- **No dual-shape decode.** `RunContext.from_map/1` does not look for
  `"pr_workflow"` or `"max_concurrency"`; a v1 map cannot reach it, because a v1
  schema aborts at boot.
- **No historical-record rendering path.** The console has no branch for
  displaying a run that recorded a run mode or a cap (spec Assumptions).
- **No migration of `prereqs` into anything.** The concept is retired, not
  relocated.

---

## 6. Operator procedure for the reset

Documented in `docs/runbook.md` as part of this feature:

```bash
# 1. Export anything worth keeping from the v1 store, BEFORE upgrading.
mise exec -- iex -S mix
iex> SpeckitOrchestrator.export_run("r000007", "/tmp/r000007.json")

# 2. Upgrade, then remove the v1 store directory.
rm -rf ~/.autonomous/mnesia

# 3. Start. A fresh v2 schema is created; the next run is run number one.
```

Step 1 is the operator's responsibility and must happen before the upgrade —
after it, the v1 store is unreadable by design (FR-023). SC-006's "the reset
persistence starts empty — the first run after the change is run number one" is
the observable outcome of step 3.
