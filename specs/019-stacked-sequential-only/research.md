# Phase 0 Research: Stacked Sequential Runs as the Only Behaviour

**Feature**: `019-stacked-sequential-only` | **Date**: 2026-07-28

All Technical Context unknowns are resolved here. Every entry is a decision
about *this* codebase — there is no new external dependency, no new library, and
no new protocol in this feature. What is being researched is how to remove two
configuration axes (run mode, concurrency) and one ordering input (prerequisites)
from a system that currently threads all three through ten modules, a Mnesia
schema, and five console views, without leaving a silent acceptance path behind.

---

## R1 — How a retired setting is refused rather than ignored

**Decision**: Three independent refusal points, one per surface, all landing in
the existing `{:error, {:preflight, problems}}` shape:

1. **Run-start options** — `run/1`, `run_spec/2`, `resume/2`, `resume_run/1`
   validate their keyword list against an allow-list of known keys before any
   side effect. `:pr_workflow` and `:max_concurrency` are named explicitly in a
   `@retired_opts` list so the refusal says *"`:pr_workflow` was retired in
   019; every run is stacked sequential"* rather than the generic unknown-key
   message. Refusal is `{:error, {:preflight, [{:retired_option, :pr_workflow}]}}`.
2. **Application environment** — a boot-time check in `Application.start/2`
   (before the supervision tree's first child) reads `Application.get_env` for
   `:pr_workflow` and `:max_concurrency`. Present ⇒ abort startup with the
   retired-setting message. This catches a stale `config/*.exs` or a
   `Application.put_env` left in a `.iex.exs`.
3. **Environment variables** — `config/runtime.exs` currently maps
   `SPECKIT_PR_WORKFLOW` and `SPECKIT_MAX_CONCURRENCY`. Both mappings are
   deleted and replaced with a `raise` when either variable is *set at all*,
   so an operator exporting one out of habit learns at boot instead of getting
   a run that silently ignores it.

**Rationale**: FR-004 and SC-005 demand refusal on *every* surface, and the
edge-case list names a stale config file and an exported env var specifically.
A single validation point cannot cover all three because they are read at
different times (opts at call, app env at boot, env var at config compile).
Principle II ("reject at the edge, never carry silently inward") is satisfied at
each edge rather than at one convenient chokepoint.

**Alternatives considered**:
- *Silently drop the keys.* Rejected outright by FR-004 — it is exactly the
  failure mode the requirement exists to prevent.
- *Accept-and-warn (log a warning, continue).* Rejected: a warning in an
  unattended long-running pipeline is indistinguishable from silence, and
  SC-005 says "attempts are refused", not "attempts are logged".
- *Keep the keys as no-ops for one release, then remove.* Rejected: FR-022
  establishes this feature as a clean break with no compatibility window, and a
  deprecation period is a compatibility window.

---

## R2 — Numeric ordering and duplicate detection

**Decision**: `Feature` gains an integer `number` field parsed from the `NNN`
filename prefix at load. Ordering compares `number` (integer), never the
filename string. `Backlog.load!/1` groups parsed features by `number` and raises
a new `Backlog.DuplicateNumberError` naming every conflicting file when any
group has more than one member. Gaps are simply absent numbers — no validation
at all, since nothing consumes contiguity.

**Rationale**: The spec's Assumptions section is explicit: *"Feature numbers are
compared numerically, so differing zero-padding widths order predictably and two
files whose numbers are numerically equal count as duplicates under FR-012."*
String comparison would sort `"1000"` before `"999"` and would treat `001` and
`1` as distinct, contradicting both halves of that assumption. Parsing once at
load and carrying the integer keeps every downstream comparison trivially
correct and removes the temptation to re-parse in a sort callback.

The existing `id` (zero-padded string, e.g. `"001"`) is **kept** as the
feature's identity — it is the branch name (`feature/001-slug`), the store key,
the checkpoint key, and every operator-facing label. `number` is ordering only.
Two fields is the honest model: identity and order are genuinely different
concerns here, and collapsing them would either break branch names or break
numeric sorting.

**Alternatives considered**:
- *Sort by zero-padded string, require uniform width.* Rejected: it makes a
  legal backlog illegal (`docs/breakdown/1000-x.md` next to `001-y.md`) and the
  spec explicitly legalizes differing widths.
- *Derive order lazily with `String.to_integer/1` inside the sort.* Rejected:
  the parse can fail, and a sort comparator is the worst possible place to
  discover a malformed id (Principle II wants that at load).
- *Detect duplicates at run start rather than backlog load.* Rejected: FR-012
  says "at load time", and the loader is already the fail-loud boundary.

---

## R3 — The parked run: representation, transitions, and refusal

**Decision**: Add `:parked` to the `speckit_run` record's `state` enum, giving
`:in_flight | :parked | :completed | :superseded`. Three new `Store.Writer`
operations, each one transaction:

- `park_run(run_key, %{stopped_by: feature_id, status: st, reason: term})` —
  `:in_flight → :parked`, recording which feature broke the chain and why.
- `continue_run(run_key)` — `:parked → :in_flight`, so the continued run keeps
  its `run_id`, its features, its cost entries, and its recorded settings.
- `end_run(run_key, outcome)` — `:parked → :completed`, writing every still-
  `:pending` feature as `:never_started` in the same transaction so a closed-out
  record is unambiguous without re-deriving anything.

`Store.Query.parked_run/1` mirrors the existing `in_flight_run/1`.
`Store.Writer.open_run/2`'s `supersede_in_flight!/2` gains a guard: a `:parked`
run for the repository aborts the transaction with `{:parked_run, run_id}`
rather than being superseded, which `run/1` surfaces as
`{:error, {:parked_run, run_id, [:continue, :end]}}` (FR-020a, FR-020b, SC-009).

**Rationale**: A parked run is a *lifecycle state of the run*, not a derived
property of its features — the spec's Key Entities section says so ("neither a
working run nor a closed-out one until the operator continues or ends it"), and
FR-019 requires it be distinguishable from both. Deriving it (e.g. "in-flight
with a non-done terminal feature and nothing running") would be re-computed
identically in five places and would silently change meaning the moment a
reconciliation rewrote a feature status. An explicit state also gives
`open_run/2` something atomic to guard against, which is what makes SC-009's
"100% of attempts refused" a transactional property rather than a race.

`:parked → :in_flight` on continue (rather than a distinct `:continuing` state)
is deliberate: a continued run *is* a working run, and every existing query,
console view, and capacity rule that already understands `:in_flight` then needs
no change.

**Alternatives considered**:
- *Derive parked-ness from feature statuses.* Rejected above — five derivation
  sites, and no atomic guard for `open_run/2`.
- *A separate `speckit_parked` table.* Rejected: a run has exactly one state at
  a time; a second table makes two rows that can disagree, which is the precise
  class of bug feature 018 existed to remove.
- *Reuse `:superseded` with a `superseded_by: nil` sentinel.* Rejected as an
  overload that reads as a bug to anyone querying run history.

---

## R4 — Collapsing the release policy

**Decision**: `Release.next_wave/4` (features, statuses, cap, breaker) is
replaced by a single pure decision function:

```elixir
@spec next([Feature.t()], %{String.t() => Feature.status()}, boolean()) ::
        {:release, Feature.t()} | :none | {:stopped, String.t(), Feature.status()}
```

Rules, evaluated in order:

1. `breaker_tripped?` ⇒ `:none` (drain, don't kill — Principle IV, unchanged).
2. Any feature in a non-done terminal status (`:escalated`/`:halted`/`:failed`)
   ⇒ `{:stopped, id, status}` (FR-014, FR-015).
3. Any feature `:running` ⇒ `:none` (one at a time is structural — FR-006).
4. Otherwise the lowest-ordered `:pending` feature ⇒ `{:release, feature}`.
5. No `:pending` features left ⇒ `:none`.

`Release.releasable?/2` and `Release.blocked?/2` are **deleted** —
`blocked?/2` has no meaning without prerequisites, and `releasable?/2` collapses
into rule 4. `Release.sequential_order/1` (the cap-1 projection the DAG view
used) becomes `Release.order/1`, a plain sort, since with prerequisites gone the
release order *is* the sort order and no replay is needed to know it.

**Rationale**: Keeping `next_wave/4`'s shape and passing `cap: 1` forever would
preserve a parameter that FR-006 says must not exist as a configured limit, and
would leave the wave-list return type implying that a wave can have two members.
Returning `{:stopped, …}` rather than an empty list is what lets the Coordinator
tell "stopped at a broken link" (park) from "nothing left to do" (close out) —
today both are `[]`, which is exactly why stop-on-first-failure could not be
expressed in the old shape.

Rule 2 before rule 3 matters: a breaker-halted in-flight feature is itself a
non-done terminal, so the chain stops for the right reason and the edge case
"cost breaker trips mid-chain" composes with no special-casing.

**Alternatives considered**:
- *Keep `next_wave/4`, hardcode cap 1 internally.* Rejected: return type lies,
  and the stopped/drained distinction stays inexpressible.
- *Put the stop decision in the Coordinator.* Rejected: it is a pure decision
  over features and statuses, and Principle I keeps decision surfaces pure and
  unit-testable. The Coordinator should *react*, not decide.
- *Return the full remaining order, let the caller take one.* Rejected: invites
  a caller to take two.

---

## R5 — Modelling the Ad-hoc group

**Decision**: `Feature` gains `group: :backlog | :ad_hoc` (default `:backlog`)
and `created_at: DateTime.t() | nil`. `SingleSpec.build/3` stamps
`group: :ad_hoc` and `created_at: DateTime.utc_now()`. Ordering within a group:

- `:backlog` — ascending `number`.
- `:ad_hoc` — ascending `{created_at, number}`; the `number` tiebreak makes the
  order **total and stable** when two ad-hoc features share a timestamp
  (the spec's "two ad-hoc features created in the same instant" edge case),
  because ids are uniquely assigned by `SingleSpec`'s taken-id gathering.

`Feature.prereqs` and the `:blocked` status are **deleted** from the struct and
the status union (FR-010, and the spec's "The blocked feature state is retired"
assumption).

**Rationale**: The group is a property of the feature, not of the run — the same
run type executes both, and every listing view must show both distinctly
(FR-027). Storing it on the struct means no view has to infer group membership
from the absence of a backlog file, which would be wrong for a run whose backlog
was renamed mid-flight.

`created_at` is only meaningful for ad-hoc features (backlog features are
ordered by an operator-chosen number), so `nil` for backlog is honest rather
than a filler timestamp that invites accidental sorting by it.

**Alternatives considered**:
- *A separate `AdHocFeature` struct.* Rejected: every consumer would need two
  clauses for what is one lifecycle; the difference is ordering rule and base
  branch, not behaviour.
- *Infer group from `path` (ad-hoc dir vs breakdown dir).* Rejected: a path is
  a location, not an identity, and the inference breaks under `Layout` changes.
- *Order ad-hoc by id only.* Rejected: ids are assigned by max-taken+1, so id
  order and creation order coincide *today* but would diverge the moment ids are
  reclaimed or an operator names one; FR-025 says creation time.

---

## R6 — Chain base resolution, and what ad-hoc does to the stack

**Decision**: `StackTracker` is kept, seeded with `Config.pr_base()`, and
advanced only by a `:done` **backlog** feature. An `:ad_hoc` feature reads
`Config.pr_base()` directly for both its worktree base and its PR base, and
never calls `set_top/2` (FR-028). On `continue_run/1` the tracker is re-seeded
from the store: the branch of the highest-numbered `:done` backlog feature in
the run, falling back to `Config.pr_base()` when none completed.

**Rationale**: FR-028 makes ad-hoc features chain-neutral in both directions —
they neither read the top nor advance it. Routing them around the tracker rather
than through it with a conditional keeps the "chain" concept meaning exactly one
thing. Re-seeding on continue is required because the tracker is per-run process
state that does not survive the park; deriving it from `:done` features rather
than persisting it avoids a second source of truth for what the store already
records (FR-018's "the completed local branch MUST still become that base" also
falls out of this — the branch exists whether or not publication succeeded).

**Alternatives considered**:
- *Persist the stack top in the run record.* Rejected: derivable from feature
  statuses plus the branch-naming convention, and a persisted copy can disagree
  with the branches that actually exist.
- *Let ad-hoc features advance the tracker.* Rejected by FR-028 explicitly, and
  it would make an unrelated one-off silently re-base the next backlog feature.

---

## R7 — Console surfaces after the collapse

**Decision**: Five view changes.

| View | Change |
|---|---|
| `TriggerLive` | Remove the stacked-PR toggle and the effective-concurrency line. The run-shape summary becomes static descriptive text (FR-005). |
| `ConfigLive` | Remove the concurrency slider and the PR-workflow toggle. `pr_base`, `pr_remote`, budget, and models stay editable. |
| `layouts.ex` status bar | Remove `run_mode/1` and `run_cap/1` entirely — no mode label, no cap number (FR-005). |
| `PipelineDagLive` | The DAG becomes a **linear chain view**: one column per group (numbered backlog, Ad-hoc), features in their group's order, each rendered as a link in the chain with its base branch (FR-027). `PipelineDagLayout`'s depth/edge computation is deleted; a chain needs no layout algorithm. |
| `MissionControlLive` | Gains the parked-run banner: which feature stopped the chain, why, and the two actions (continue / end) — FR-019, SC-008. |

**Rationale**: FR-005 forbids "a mode label, toggle, or comparison implying an
alternative", which rules out keeping the toggle disabled or showing "mode:
stacked". The DAG view is the largest change because its entire premise —
prereq depth as columns — is gone; a chain is one-dimensional and the honest
rendering of it is a list, not a graph with one node per layer.

**Alternatives considered**:
- *Keep the DAG view, render a degenerate one-node-per-layer graph.* Rejected:
  visually implies a dependency structure that no longer exists.
- *Put the parked banner on a dedicated `/parked` route.* Rejected: SC-008 wants
  the pending decision visible, which means on the view an operator already has
  open, not one they must know to visit.

---

## R8 — How "continue" maps onto the existing resume machinery

**Decision**: `continue_run/1` reuses `resume_run/1`'s machinery wholesale and
adds exactly one thing before it: flipping the store state `:parked → :in_flight`.
Concretely — `continue_run/1` → `Store.Writer.continue_run(run_key)` →
`Recovery.reconcile_run/2` (unchanged) → re-seed `StackTracker` per R6 → start
the Coordinator with the same `run_key`. The feature that broke the chain is
`:escalated`/`:halted`/`:failed` in the record; `continue_run/1` resets **only
that feature** to `:pending` so it re-runs from its checkpoint (FR-019a's
"continuing re-runs the feature that broke the chain"); every other feature keeps
its reconciled status.

`resume/2`'s per-feature options (`:prompt`, `:from`, `:remediation_prompt`,
`:remediation_model`, `:from_task_phase`) remain available on `continue_run/1`
and apply to the stopping feature, since that is the only one being re-run.

**Rationale**: The continue path and the crash-resume path want identical
behaviour after the state flip — restore the run, reconcile against durable
evidence, release in order. Building a second path would duplicate
`restore_run_scope/2`'s capacity preflight, ledger restoration, and context
merge, and the two would drift. FR-019c ("without the operator restating any
run-shape setting") is already satisfied by `RunContext.merge/2`, which needs no
change beyond losing two fields.

**Alternatives considered**:
- *Make continue a fresh `run/1` seeded with prior statuses.* Rejected: it would
  open a new `run_id`, breaking FR-020's "the continued run" identity and
  splitting cost accounting across two records.
- *Auto-continue on `resolve/1`.* Rejected explicitly by FR-019a and the
  clarification session — the operator chooses at resolve time.

---

## R9 — Executing the persistence reset

**Decision**: Bump `Store.Migrations.current_version/0` to `2` and register
version 2 as a **refusal migration**: a migration entry whose function returns
`{:error, {:incompatible_record, from_version}}` rather than transforming
anything. Startup on a v1 schema therefore aborts with a message naming the
incompatibility (FR-023), and the operator's remedy — documented in
`docs/runbook.md` — is to delete `Config.store_dir/0` and let a v2 schema be
created fresh.

The schema itself changes with the reset: `speckit_feature` loses `:prereqs` and
gains `:group` and `:created_at`; its status union loses `:blocked` and gains
`:never_started`; `speckit_run`'s state union gains `:parked` and the record
gains `:stopped_by` and `:stopped_reason`.

**Rationale**: The constitution requires schema evolution to be "explicit and
versioned" with migrations applied at startup, and requires an unrecognized
version to fail loud. FR-022/FR-023 require *refusing* a pre-change record
rather than migrating it. A refusal migration satisfies both readings: the
version bump is explicit and registered in the same ordered list every other
migration lives in, and the "migration" that would run is precisely the loud
refusal the spec asks for. Deleting the schema out-of-band with no version bump
would leave a v1 directory silently readable by a v2 build.

**Alternatives considered**:
- *Write a real v1→v2 `transform_table` migration.* Rejected by FR-022 — "MUST
  NOT carry a compatibility path" — and it would be dead code by construction,
  since the reset guarantees no v1 record exists.
- *Delete the store directory automatically at boot.* Rejected: silent
  destruction of recorded state, directly against the constitution's "MUST NEVER
  be handled by silently dropping recorded state".
- *Leave `current_version` at 1 and change tables in place.* Rejected: a build
  would read a differently-shaped v1 record as if it were its own.

---

## R10 — Where the one-feature-at-a-time rule is actually enforced

**Decision**: Structurally, in `Release.next/3` rule 3 (any `:running` ⇒
`:none`), with no counter and no cap parameter anywhere in the system. The
Coordinator's `inflight` set remains, but only as bookkeeping for the drain
check (`MapSet.size(inflight) == 0`), never as a capacity comparison.

**Rationale**: FR-006 requires "a structural property rather than a configured
limit". A `cap` field defaulting to 1 is a configured limit with a default; a
rule that refuses to release while anything runs is structural — there is no
value that could be set to make it release two. This is also what makes SC-002's
"maximum of one feature in flight at every point" provable by inspection of one
function rather than by auditing every caller for the cap it passed.

**Alternatives considered**:
- *Keep `cap: 1` in the Coordinator struct.* Rejected: FR-007 requires the
  concurrency setting removed from "the recorded per-run settings", and a struct
  field surfaced in `status/0`'s snapshot is exactly that.

---

## Summary of resolved unknowns

| # | Unknown | Resolution |
|---|---|---|
| R1 | Refusing retired settings on every surface | Three refusal points: opts allow-list, boot-time app-env check, `runtime.exs` raise |
| R2 | Numeric ordering, duplicate detection | Integer `number` field parsed at load; `DuplicateNumberError`; gaps legal |
| R3 | Parked-run representation | New `:parked` run state + `park/continue/end` writers + `open_run/2` guard |
| R4 | Release policy shape | `Release.next/3` → `{:release, f} \| :none \| {:stopped, id, status}` |
| R5 | Ad-hoc group modelling | `group` + `created_at` on `Feature`; `prereqs`/`:blocked` deleted |
| R6 | Chain base + ad-hoc neutrality | `StackTracker` advanced only by `:done` backlog features; re-seeded on continue |
| R7 | Console changes | Toggle/slider/mode-label removed; DAG → chain view; parked banner |
| R8 | Continue vs. resume | `continue_run/1` = state flip + `resume_run/1` machinery, same `run_id` |
| R9 | Persistence reset | Schema v2 + refusal migration; operator deletes `store_dir` |
| R10 | One-at-a-time enforcement | Structural rule in `Release.next/3`; no cap field anywhere |

No NEEDS CLARIFICATION markers remain.
