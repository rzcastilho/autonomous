# Phase 0 Research: Resume Preserves Backlog Scope

**Feature**: `016-resume-backlog-scope` | **Date**: 2026-07-26

Ten decisions. Each names what was chosen, why, and what was rejected. No
`NEEDS CLARIFICATION` remains in the Technical Context.

---

## D1 — Per-feature resume becomes a whole-run continuation with one override

**Decision**: `SpeckitOrchestrator.resume/2` stops building a one-feature run.
It reads the single-slot run manifest, restores the **full recorded feature
set**, reconciles every restored feature (D4), seeds the Coordinator with the
reconciled statuses, and dispatches only what needs dispatching — exactly the
shape `resume_run/1` already uses. The one thing that differs from
`resume_run/1` is a **per-feature override** for the named feature: its start
phase (`:from` / checkpoint), `:prompt`, `:remediation_prompt`,
`:remediation_model`, `:from_task_phase`, and `reset_implement_sessions: true`.

Mechanically: `resume/2` and `resume_run/1` converge on one private
`continue_run/2` that takes `{features, statuses, resume_phases, layout,
context}` plus an optional `%ResumeTarget{}`. The runner injected into the
Coordinator switches on `feature.id`: the target id goes through today's
`resume_runner/7`/`resume_executor/7` (unchanged, so its dispatch is
byte-identical — SC-005); every other feature goes through `resume_run/1`'s
existing `dispatch_resume/6`.

**Rationale**: Spec Assumptions state this outright ("The whole-run resume path
is the model"). The machinery to restore a full set, seed statuses, and dispatch
selectively already exists, is tested (`resume_run_test.exs`,
`recovery_test.exs`), and is the only path that has ever been correct here.
Sharing it makes the two resume verbs one behaviour with one knob rather than
two mechanisms that can drift apart again.

**Alternatives rejected**:

- *Keep `resume/2` narrow, document `resume_run/1` for backlog runs.* Explicitly
  rejected in the spec: it leaves the destructive default in place.
- *Have `resume/2` call `resume_run/1` and pass the override through opts.*
  `resume_run/1` re-reads the manifest and re-reconciles; threading a
  single-feature override through its public option list widens a contract that
  should stay whole-run. A shared private path is cheaper and keeps both public
  contracts as they read today.
- *Merge into one public function.* Breaks two documented contracts
  (`specs/005-resume-facade`, `specs/009-crash-recovery`) and every caller,
  including `EscalationsLive`, for no behavioural gain.

---

## D2 — Operator intent governs the target feature's start phase

**Decision**: For the **named** feature, phase resolution is unchanged from
today: `:from` override > checkpoint `last_phase` (with the `in_progress` →
next-phase rule) > error. Reconciliation's `{:resume, phase}` verdict does
**not** override it, and a reconciled verdict of `:done` / `:escalated` /
`:halted` for the target does not veto the resume — the operator asked for it
explicitly. The target's status seed is forced to `:pending` so the Coordinator
releases it. Any divergence between the reconciled verdict and the operator's
request is **reported** in the resume's log line, not silently applied.

For **every other** restored feature, the reconciled verdict is authoritative
(D4).

**Rationale**: SC-005 requires that once a resume is permitted to start, a
single-feature run and a no-manifest run dispatch *exactly the work they
dispatch today*. Reconciliation deriving the phase from the last committed git
boundary can legitimately differ from the checkpoint-derived phase; letting it
win would change what a plain `resume("001", from: :plan)` executes. Principle V
also puts the human above the automated verdict at a gate.

**Alternatives rejected**:

- *Reconcile the target too and let evidence win.* Silently retargets the
  operator's requested phase; breaks SC-005 and the `:from` contract.
- *Refuse the resume when the target reconciles to `:done`.* Punishes the exact
  operator who is repairing a damaged run (US3's continuation).

---

## D3 — `clear/0` is the supersede signal; resume paths stop clearing

**Decision**: `run/1` gains `:supersede` (default `true`). `true` keeps today's
`RunManifest.clear/0` — a fresh run legitimately replaces its repo's record
(FR-013). Both resume paths (`resume/2`, `resume_run/1`) pass `supersede:
false`, so the existing record survives until the Coordinator's first write.

**Rationale**: The anti-narrowing guard (D4) can only compare a proposed write
against a record that is still there. Today `run/1` clears unconditionally, so a
narrowed resume would sail past any guard. Making the clear explicit turns
"fresh run" vs "continuation" into a single declared bit at the one place that
knows the difference, instead of inferring intent inside the writer.

**Alternatives rejected**:

- *Guard reads a shadow copy taken before `clear/0`.* Hidden state, racy across
  a crash between clear and write, and it still cannot distinguish a deliberate
  fresh start from a narrowing.
- *Never clear; let the guard classify every write.* The guard would have to
  decide whether a completely different feature set is a new run or corruption —
  exactly the guess Principle II forbids.

---

## D4 — Whole-run reconciliation is reused verbatim, split into plan + apply

**Decision**: Reuse `Recovery.reconcile_run/2` (feature 014) for every restored
feature — same `Evidence` collector, same pure `Reconcile` table, same
`{:resume, phase}` / `{:conflict, reason}` outputs, same "never invent a state"
rule. It is refactored into:

- `Recovery.plan_run/2` — collect + reconcile, returns `{:ok, %{statuses,
  resume_phases, report}}`, **writes nothing**;
- `Recovery.reconcile_run/2` — `plan_run/2` + the existing manifest rewrite.
  Behaviour and return shape unchanged for existing callers.

`resume/2` and `resume_run/1` use `reconcile_run/2` (they are about to run and
the corrected record should be durable); US3's preview uses `plan_run/2`
(FR-019a demands the preview have no durable effect).

**Rationale**: Clarification session answer — "reusing the existing whole-run
reconciliation." The write is the only impure part of `reconcile_run/2`, so
lifting it out is a two-line split, not a new mechanism, and it is what makes a
no-side-effect preview possible at all.

**Alternatives rejected**:

- *A `dry_run: true` flag on `reconcile_run/2`.* A boolean that changes whether
  a function persists is exactly the shape that gets passed wrong once.
- *Trust the recorded statuses for non-target features.* Contradicts FR-002a and
  reintroduces 014's stale-`running` bug on the resume path.

---

## D5 — The anti-narrowing guard lives in `RunManifest.write/1`, identity-based

**Decision**: `write/1` reads the record currently at the resolved segment path
before writing. If any **currently-recorded feature id is absent from the
proposed set**, the write is refused: the existing file is left untouched, a
telemetry event is emitted (D6), and `write/1` still returns `:ok` (FR-014 —
recording is a durability concern and never takes down a run). Comparison is
`MapSet.difference(recorded_ids, proposed_ids)` — identity, not count, so a swap
is refused too (clarification session; FR-011, SC-004).

**Rationale**: `write/1` is the single choke point every path funnels through
(Coordinator per-phase, `Recovery` rewrite, future callers), so guarding it
makes the class of defect non-recurring rather than patching one caller. Reading
one small JSON file per write is negligible beside a phase's runtime.

**Alternatives rejected**:

- *Guard in the `Coordinator`.* Only covers today's writer; `Recovery` and any
  future writer bypass it — this is precisely how the bug arrived.
- *Guard in `run/1` before starting.* Cannot see per-phase writes, and the
  narrowing is only visible at write time.
- *Count-based comparison.* Rejected in clarification: a swap loses work as
  surely as a shrink.

---

## D6 — Refusal is a run-level telemetry event, folded by the existing path

**Decision**: New event `[:speckit, :run, :scope_narrowing_refused]`,
measurements `%{dropped_count: n}`, metadata `%{segment, recorded: [ids],
attempted: [ids], dropped: [ids]}`. It joins `Telemetry.events/0`, gets a
`handle_event/4` clause in the default logger, an `apply_event/4` clause in the
pure `ConsoleReadModel` (a `:warn` feed entry with `feature_id: nil`), and a
`broadcast_diff/4` clause in `ConsoleProjection` that broadcasts the feed entry
only (no feature slice — this is run-level).

**Rationale**: Clarification session answer: "a telemetry event that both the
default logger and the console activity feed fold, matching existing run
signals." `ConsoleProjection` already attaches to `Telemetry.events/0` wholesale,
so adding the name is the whole wiring. `event_entry.feature_id` is already
`String.t() | nil`, so a run-level entry needs no type change.

**Alternatives rejected**:

- *`Logger.warning` only.* Invisible in the console — the surface where an
  operator would notice.
- *Return `{:error, :would_narrow}` from `write/1`.* Changes a `@spec :: :ok`
  contract with ~6 call sites and risks a caller treating persistence failure as
  fatal, violating FR-014.

---

## D7 — Per-feature resume gets the same live-run refusal as whole-run resume

**Decision**: `resume/2` calls the existing `guard_active_run/1` first, honouring
the same `:force` opt. Returns `{:error, {:active_run, pid}}` and starts no work.
`EscalationsLive` renders it via `format_resume_error/1` with a hint that the run
is already live.

**Rationale**: Clarification session answer ("refuse, with the same explicit
force override"). Now that `resume/2` starts a *whole-run* Coordinator, two
concurrent resumes would race on the same repo's manifest slot, worktrees and
budget — the very damage this feature exists to prevent. `guard_active_run/1`
already exists and already implements the override.

**Note**: `start_run/2`'s `stop_previous_run/0` stops a *finished-but-alive*
named Coordinator; the guard fires earlier and only for an **unfinished** one, so
the two do not conflict.

---

## D8 — No readable manifest ⇒ today's single-feature path, unchanged

**Decision**: When `RunManifest.read/0` returns `{:error, :no_manifest}` or
`{:error, :corrupt}`, `resume/2` falls back to exactly today's behaviour:
checkpoint identity, one-feature run, `supersede: false` still passed (nothing to
narrow — the guard is a no-op against an absent record). Same when the manifest
is readable but names features while the resumed id is absent from it: the target
is **appended** to the restored set (FR-008), never substituted for it.

**Rationale**: FR-009 and the spec's edge cases make resume-without-a-record an
existing guarantee. Feature 007's whole point was that `resume(id)` alone
suffices with no loadable backlog.

**Alternatives rejected**: *Refuse without a manifest.* Regresses 007 and blocks
the operator exactly when durable state is already damaged.

---

## D9 — US3 recovery is a new `Recovery.Rebuild` + a preview/confirm facade verb

**Decision**: New pure module `Recovery.Rebuild` computes a **rebuild proposal**
from three inputs — the (possibly narrowed) manifest record, the backlog on disk
(`Backlog.load!/1` over the layout's `breakdown_root`), and per-feature
`Recovery.Evidence`. It returns the union feature set, a per-feature reconciled
status, and a `discrepancies` list (`:absent_from_backlog`,
`:absent_from_record`, `:unreconcilable`). New facade verb
`SpeckitOrchestrator.recover_record/1`:

- default — returns `{:ok, proposal}` and writes nothing (FR-019a);
- `confirm: true` — writes the rebuilt record via `RunManifest.write/1` and
  returns `{:ok, :written, proposal}`;
- refuses with `{:error, reason}` and writes nothing when the backlog cannot be
  loaded or the proposal is internally inconsistent (FR-020).

Confirmation writes a **superset** of the recorded features, so the D5 guard
never fires against it.

**Rationale**: Clarification session answer ("preview by default, explicit
confirmation before writing"). The union-with-discrepancies shape is what lets
recovery *report* rather than guess about a backlog that changed since the run
started (FR-018).

**Alternatives rejected**:

- *Fold recovery into `resume_run/1`.* FR-019 forbids it running automatically.
- *Rebuild from the backlog alone.* Discards the surviving per-feature record and
  would re-run completed features, breaking SC-006.

---

## D10 — Test strategy: pure-first, then a chained-backlog regression

**Decision**: Three layers.

1. **Pure/hermetic** — `Recovery.Rebuild` (union + discrepancy table) and the
   `RunManifest.write/1` guard (fake segment root under `tmp`, no Coordinator);
   telemetry assertions via `:telemetry_test.attach_event_handlers/2`;
   `ConsoleReadModel` fold via a synthetic event. These carry the >90% pure-core
   requirement.
2. **Seam-level** — the resume dispatch decision through the Coordinator's
   `:runner`/`:manifest` seams: assert the restored feature set, the seed
   statuses, which ids were dispatched and at which phase. No CLI, no worktree.
   Extends `resume_test.exs` / `resume_run_test.exs` conventions.
3. **Regression (SC-003)** — a three-feature chained backlog `001 → 002 → 003`
   with `001` halted, resumed once, asserting all three reach terminal states and
   the final report counts three. Modelled on `recovery_quickpoll_test.exs`
   (tmp git repo + FakeSDK, `async: false`).

**Rationale**: Matches the constitution's Quality & Test Discipline (pure core
>90%, injected seams for wave/DAG logic, real side effects opt-in) and the
existing suite's split. SC-003 is a behavioural claim about a whole run, so it
needs the third layer; everything else is provable without one.

**Alternatives rejected**: *Only an end-to-end test.* Slow, non-hermetic, and it
would leave the guard and the rebuild table under-covered where the risk of
silent wrongness is highest.
