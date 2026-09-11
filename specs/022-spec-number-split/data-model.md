# Data Model: Spec Number Split

Phase 1 output. Entities are the spec's Key Entities, expressed as the concrete
structs, records, and signal maps the implementation changes.

## 1. `SpeckitOrchestrator.Feature`

The work unit. Gains one field.

| Field | Type | Change | Meaning |
|---|---|---|---|
| `id` | `String.t()` | — | wave-local zero-padded number, e.g. `"001"`. **Canonical identity**: store key, operator label, breakdown filename, telemetry `feature_id`. |
| `number` | `pos_integer()` | — | `id` as an integer; sole ordering key (`Release.order/1`). |
| `slug` | `String.t()` | — | kebab-case name. Shared by the spec directory and the branch. |
| `path` | `String.t()` | — | breakdown file path. |
| `group` | `:backlog \| :ad_hoc` | — | allocation rule does not depend on it. |
| `created_at` | `DateTime.t() \| nil` | — | `:ad_hoc` only. |
| `status` | `status()` | — | lifecycle. |
| **`spec_number`** | **`pos_integer() \| nil`** | **new** | repo-monotonic spec number. `nil` until allocated. Governs the spec directory, the branch name, and artifact resolution — **nothing else**. |

`spec_number` is deliberately **not** in `@enforce_keys`: a feature parsed from
the backlog has no spec number yet, and a feature that never starts never gets
one.

### Derived accessors

```elixir
@spec spec_id(t()) :: String.t()
# Zero-padded spec number for PATH AND BRANCH composition.
# Falls back to `id` when `spec_number` is nil (dry runs, the pure unit suite,
# and wave 1 where the two coincide anyway). See research R3.

@spec spec_label(t()) :: String.t() | nil
# Zero-padded spec number for OPERATOR SURFACES. `nil` when unallocated, so a
# surface reports "not allocated" instead of borrowing the wave number.
```

Zero-padding is `String.pad_leading(Integer.to_string(n), 3, "0")` — the same
shape `Backlog` produces for `id`, so a number above 999 widens rather than
truncating.

### Invariants

- `id`/`number` and `spec_number` are independent. Equality is a wave-1
  coincidence, never a rule.
- The spec directory `specs/<spec_id>-<slug>` and the branch
  `feature/<spec_id>-<slug>` are composed from the same two values, so they
  cannot drift apart (FR-005).
- Once recorded, `spec_number` is never reallocated for that feature (FR-004).

## 2. `SpeckitOrchestrator.SpecNumber` (new, pure)

No struct. A pure decision surface over directory *names*, with all IO supplied
by the caller.

```elixir
@type entry :: String.t()          # a bare directory name, e.g. "015-billing"

@spec parse(entry()) :: {:ok, pos_integer()} | :error
# "015-billing" -> {:ok, 15}; "autonomous" | "015" | "abc-x" | "" -> :error

@spec highest([entry()]) :: pos_integer() | nil
# nil when no entry conforms

@spec allocate([entry()], String.t()) ::
        {:ok, pos_integer()} | {:error, {:spec_dir_exists, String.t()}}
# allocate(entries, slug):
#   n = (highest(entries) || 0) + 1
#   refuse when any entry's number == n, naming that entry (FR-003a)
#   otherwise {:ok, n}

@spec dir_name(pos_integer(), String.t()) :: String.t()
@spec branch_name(pos_integer(), String.t()) :: String.t()
```

Conforming shape: `^(\d+)-(.+)$`. A leading run of digits followed by `-` and a
non-empty remainder. Numeric comparison, so `002` and `0002` are the same number
(consistent with `Backlog`).

## 3. `SpeckitOrchestrator.Checkpoint` (new, pure)

The empty-checkpoint decision table — the direct analogue of `Remediation.next/2`
sitting under `Pipeline.next/3`.

```elixir
@armed_phases [:specify, :plan, :tasks]

@type commit_result :: :ok | :noop | {:error, term()}

@spec verdict(Pipeline.phase(), boolean(), commit_result()) ::
        :advance | {:failed, {:empty_checkpoint, Pipeline.phase()}}
```

| phase | `artifact_absent_at_start?` | commit result | verdict |
|---|---|---|---|
| `:specify` / `:plan` / `:tasks` | `true` | `:noop` | `{:failed, {:empty_checkpoint, phase}}` |
| `:specify` / `:plan` / `:tasks` | `true` | `:ok` | `:advance` |
| `:specify` / `:plan` / `:tasks` | `true` | `{:error, _}` | `:advance` (a git failure is not evidence the phase wrote nothing) |
| `:specify` / `:plan` / `:tasks` | `false` | any | `:advance` (FR-014a) |
| `:clarify` / `:analyze` / `:implement` / `:converge` | any | any | `:advance` (FR-015) |

`{:empty_checkpoint, phase}` is a distinct reason shape from the artifact gate's
`{:missing_artifact, phase, artifact}` (FR-013).

## 4. Phase gate signals

`RunFeaturePhase` emits one new key. All existing keys keep their meaning and
byte-shape.

| Signal | Type | Phases | Meaning |
|---|---|---|---|
| `artifact_absent_at_start?` | `boolean()` | `:specify`, `:plan`, `:tasks` | The phase's named artifact was unresolvable in this feature's spec directory at the moment the phase started. Probed with `SpecDir.file/3` before the harness request. |

Absent for every other phase, and absent when there is no worktree (dry runs) —
`Checkpoint.verdict/3` reads a missing key as `false`, so an unarmed run behaves
exactly as it does today.

Artifact map for the probe (`:specify` is armed for this net only, and is **not**
added to the artifact gate's `@phase_artifacts`):

```elixir
%{specify: "spec.md", plan: "plan.md", tasks: "tasks.md"}
```

## 5. Store record `speckit_feature_run` — schema v5

One appended attribute.

```
:key, :run_key, :feature_id, :slug, :path, :number, :group, :created_at,
:status, :terminal_reason, :worktree_path, :branch, :pr_description,
:started_at, :ended_at, :pr_url, :advanced_with_findings,
:spec_number                                                  # <- v5
```

| Attribute | Type | Written by |
|---|---|---|
| `spec_number` | `pos_integer() \| nil` | `Store.Writer.record_spec_number/3`, once, at allocation — before the worktree exists. `nil` for a feature that never started. |

**Migration 5** — `append feature_run.spec_number`, backfilled from the row's own
`:number` (FR-007: a pre-022 feature built in a directory named for its wave
number). A transform, not a refusal. `Migrations.current_version/0` → `5`.

## 6. Spec directory / feature branch

Not structs; naming contracts.

| Thing | Before | After |
|---|---|---|
| spec directory | `specs/<id>-<slug>` | `specs/<spec_id>-<slug>` |
| feature branch | `feature/<id>-<slug>` | `feature/<spec_id>-<slug>` |
| worktree path | `<worktree_root>/<id>-<slug>` | `<worktree_root>/<spec_id>-<slug>` |
| `SPECIFY_FEATURE_DIRECTORY` | `specs/<id>-<slug>` | `specs/<spec_id>-<slug>` |
| boundary commit subject | `speckit: <id> checkpoint after <phase>` | **unchanged** — `id` is the canonical identity, and `Recovery.Evidence`'s `@boundary_re` parses it. |

The worktree path follows the branch because `Worktree.locate/2` composes both
from the same struct; keeping them on different numbers would be a second naming
rule with no reader.

## 7. Relationships

```
Breakdown package (wave)
  └─ 1..N Feature            id/number unique within the package (FR-016)
        ├─ spec_number       unique within the target repository
        ├─ 1 spec directory  specs/<spec_id>-<slug>
        ├─ 1 feature branch  feature/<spec_id>-<slug>
        └─ 1 feature_run row keyed by (repo_id, run_id, feature_id)  ← wave id
```

The store key stays the wave id. The spec number is an attribute of the row,
never part of its key (Clarification 1).
