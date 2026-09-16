# Research: Elapsed Is Execution Time

**Feature**: `024-elapsed-execution-time` | **Phase**: 0 | **Date**: 2026-09-16

All findings come from reading the code on `main` (post-023). No NEEDS
CLARIFICATION markers were raised by the Technical Context; the research
tasks below are the integration points the design depends on.

## R1. Where recorded execution windows come from

**Decision**: every element of a recorded feature's `phase_attempts` list
(as `SpeckitOrchestrator.run_detail/1` returns it) is one recorded window
`[started_at, ended_at]`, regardless of its `phase` atom; an attempt missing
either timestamp yields no window.

**Rationale**: `Store.Records.PhaseAttempt` carries `started_at`, `ended_at`,
`duration_ms` on every row, and every recorder writes all three from
`DateTime.utc_now/0` at the step's own edges:

| Recorder | `phase` | Window covers | Overlaps |
|---|---|---|---|
| `FeatureRunner.loop/12` → `record_attempt/9` | pipeline phase | `started_at` taken *before* `run_step`, `ended_at` after the boundary commit — i.e. the whole step | for `:implement`, spans every chunk; for `:analyze`, spans every superseded analyze run *and* every correction (the loop runs inside `PhaseStep.run` calls that `loop/12`'s one `started_at` precedes) |
| `FeatureRunner.run_remediation/4` | `:remediation` (pre-phase step, ordinal 1) | the corrective session | none |
| `ChunkRunner.record_chunk_attempt/6` | `:implement_chunk` | one chunk session | inside the `:implement` roll-up |
| `AnalyzeRunner.record_analyze_run/3` | `:analyze` (superseded run, own ordinal) | one analyze session | inside the final `:analyze` record |
| `AnalyzeRunner.do_record_remediation_attempt/8` → `Writer.record_remediation_attempt/2` | `:auto_remediation` | one correction session | inside the final `:analyze` record |

So the spec's two double-counting traps (implement roll-up over chunks; final
analyze over superseded runs and corrections) are exactly interval
containment, and a union over intervals counts each once (SC-006). A
superseded re-run of a whole phase after a resume-from-earlier-phase (spec
US2-4) is a separate, non-overlapping window and counts in full.
`Store.Query.feature_detail/1` already sorts attempts into execution order;
the union does not depend on that order.

**Alternatives considered**:
- *Sum `duration_ms` of pipeline-phase attempts only* — double counts nothing
  today, but silently drops the pre-phase `:remediation` step (a real
  session the pipeline spent), and breaks the moment a recorder's window
  shape changes. Rejected: the union is shape-independent.
- *Sum `duration_ms` of every attempt, subtracting known containments* —
  requires the hydration code to know which phase names nest in which.
  Rejected: interval merge needs no such table.

## R2. Where live execution windows come from

**Decision**: the console fold (`ConsoleReadModel.apply_event/4`) opens a
window on the `:start` of a `[:speckit, :phase]`, `[:speckit, :remediation]`,
or `[:speckit, :chunk]` span from the span's `system_time` measurement, and
closes it on that span's `:stop` or `:exception` from the `duration`
measurement (`to = from + duration`). Windows are keyed
`{event_kind, phase}` so a stop closes the open window of its own kind.

**Rationale**: `:telemetry.span/3` emits `start` with
`%{system_time, monotonic_time}` and `stop`/`exception` with
`%{duration, monotonic_time}` — both in **native** time units. `system_time`
is `:erlang.system_time/0` — the wall clock, the same domain as the
recorders' `DateTime.utc_now/0` (R3). The projection already receives these
measurements (`handle_telemetry/4` forwards them verbatim) and discards them;
the spec's assumption "the console already receives a phase's start and
finish… it currently discards the timing and will begin keeping it" is
confirmed. Every `[:speckit, :phase]` emitter (`PhaseStep.run_once/6`,
`FeatureRunner.run_remediation/4`, `FeatureRunner.run_chunked_phase/8`) uses
`:telemetry.span/3`, so the measurements are always present in production.

Which spans matter: `[:speckit, :phase]` covers pipeline phases, the
pre-phase remediation step, and — because `run_chunked_phase/8` wraps the
whole `ChunkRunner.run/1` — every implement chunk. It does **not** cover
analyze-loop corrections: `AnalyzeRunner` emits `[:speckit, :remediation]`
*between* two `[:speckit, :phase]` (`:analyze`) spans, so those must be
folded too or a correction's minutes would be invisible until its record
lands. `[:speckit, :chunk]` spans are nested inside the implement phase span
and add nothing to the union; they are folded anyway so the algebra has one
rule ("every span is a window") rather than a list of exceptions.

A `:stop` whose `:start` was never observed (the console came up mid-phase)
finds no open window and contributes nothing — the phase's time arrives with
its record (spec edge case 2). A repeated `:start` for an open key replaces
the open window (never observed in practice; defined so the fold is total).

**Alternatives considered**:
- *Use `monotonic_time` from start and stop* — same process, so consistent
  within a session, but not comparable to the recorded `DateTime`s, which
  the union must merge with. Rejected.
- *Use `DateTime.utc_now/0` inside the fold at `:start`* — the fold would
  read the clock (Principle I) and the value would lag the span's own
  timestamp by the mailbox hop. Rejected: the measurement is already there.

## R3. Clock domains

**Decision**: all windows are wall-clock milliseconds since the Unix epoch.
Recorded: `DateTime.to_unix(dt, :millisecond)`. Live:
`System.convert_time_unit(system_time, :native, :millisecond)` and
`System.convert_time_unit(duration, :native, :millisecond)`. `now`:
`DateTime.utc_now/0`, converted the same way at the algebra's edge.

**Rationale**: three sources, one domain. The Coordinator's per-feature
`elapsed_ms` is `System.monotonic_time(:millisecond) - started` — a
monotonic, since-release-in-this-process counter that cannot be placed on the
wall-clock axis and is exactly what FR-009 excludes. It stays on
`Coordinator.status/0` for `Report.format_status/1` and is dropped in
`ConsoleReadModel.merge_per_feature/2` before rows are built, so no layering
rule can fall back to it.

**Alternatives considered**: keeping the Coordinator counter as a fallback
when a feature has no windows yet (023's `record || live` rule). Rejected by
FR-009 and FR-010: a feature with no recorded and no live execution reads
`—`, and a just-released feature's live phase `:start` arrives before any
meaningful counter value could.

## R4. Union, not sum

**Decision**: `ExecutionTime.elapsed_ms(windows, now)` closes each open
window at `max(now, from)`, sorts by `from`, merges every pair that
overlaps or touches, and sums the merged lengths. Empty input → `nil`.

**Rationale**: FR-001 defines ELAPSED as "the total time during which at
least one execution… was running — every moment counted once". That is the
measure of a union of intervals, and it makes FR-002's overlap rule, FR-004's
live/recorded reconciliation ("differ by a few milliseconds at the edges…
treated as one span"), and SC-006 fall out of one operation instead of
three special cases. Windows for the same execution from the two sources
overlap almost entirely (the recorder's `started_at` precedes the span's
`system_time` by microseconds; the record's `ended_at` follows the span's
end), so their union is the wider of the two and the value never dips when
the record replaces the live window (FR-004, SC-004).

**Alternatives considered**: sum with per-source precedence ("record
replaces live for the same phase") — needs a matching rule between a record
and a span (phase + ordinal, which the span does not carry) and still double
counts the analyze loop. Rejected.

## R5. Where `now` enters

**Decision**: `ConsoleHydration.layer/3` and `apply_update/3` take `now`
(`DateTime.t()`), as `from_record/3` and `ConsoleReadModel.hydrate/3` already
do. `overlay_observed/1` becomes `overlay_observed/2` to thread it. The
LiveViews' `:feature_updated` handlers pass `DateTime.utc_now()`; their
seed/reconcile paths already pass it to `hydrate/3`.

**Rationale**: the row's `elapsed_ms` must be a rendered integer (the
templates and `format_elapsed/1` are unchanged, FR-014) and must advance on
each refresh while a phase is open (FR-003). Computing it in the pure layer
with an injected `now` keeps the union and the monotone clamp testable with
a fixed clock (FR-012) and keeps the LiveViews thin. The refresh cadence is
unchanged: the 2 s reconcile tick re-runs `hydrate/3`, and each
`:feature_updated` re-runs `apply_update/3`; no new timer (spec
Assumptions).

**Alternatives considered**: storing only `windows` on the row and calling
`elapsed_ms/2` from the template with `DateTime.utc_now()` — moves a clock
read and a computation into HEEx, and loses the monotone clamp between
updates. Rejected.

## R6. Closing an open window at feature terminal

**Decision**: `FeatureRunner.emit_terminal/4` adds
`system_time: System.system_time()` to the `[:speckit, :feature, :terminal]`
measurements; the fold closes every open window of that feature at that
instant. A terminal event without `system_time` (an older emitter, a
hand-built test event) leaves the windows untouched.

**Rationale**: `:telemetry.span/3` closes a span on every exit path
(`:stop` on return, `:exception` on raise, then re-raise), so an open window
at terminal only arises when a span's process died without unwinding —
precisely the "runner crash" edge case the spec assigns to the terminal
event. Adding one measurement is the smallest change that gives the fold a
timestamp in the right clock domain without reading the clock itself.
Leaving windows untouched when the measurement is absent keeps FR-011
(never lowers, never invents) over FR-005 in a case that cannot occur with
the shipped emitter; the contract names `system_time` as required on this
event.

**Alternatives considered**: close at `from` (zero-length) — lowers the
value below what was shown live, violating FR-011. Read
`System.system_time()` in the fold — Principle I. Both rejected.

## R7. Existing tests pass tiny native measurements

**Finding**: `console_read_model_test.exs` drives the fold with
`%{system_time: 1}` and `%{duration: 100}`. Converted from native (ns on
the supported platforms) those are `0 ms`, so the affected tests produce
zero-length or near-zero windows and their existing assertions (phase cells,
spend, feed) are unaffected. New fold tests craft measurements with
`System.convert_time_unit(ms, :millisecond, :native)` so window arithmetic
is asserted in milliseconds. `mission_control_live_test.exs` already emits
`system_time: System.system_time()` on its live `:start` events, so those
scenarios gain a real open window without edits — their elapsed assertions
change from "non-`—`" to the execution-time value.

## R8. Which live events reach the views between reconcile ticks

**Finding**: `ConsoleProjection.broadcast_diff/4` sends `:feature_updated`
for `[:speckit, :phase, *]`, `[:speckit, :feature, :terminal]`, and
`[:speckit, :publish, :opened]` only; `[:speckit, :chunk, *]` and
`[:speckit, :remediation, *]` update the projection but are picked up by the
next 2 s reconcile. This is unchanged and sufficient: a chunk's window is
inside the already-open implement phase window, and a correction's window
becomes visible within one tick, which SC-004's "never jumps by more than one
refresh interval" already tolerates. No new broadcast is added.

## R9. Superseding 023's artifacts

**Decision**: `specs/023-console-restart-hydration/` is not edited. This
feature's `contracts/execution-time.md` states which 023 rules it replaces
(§1.7 elapsed; the `elapsed_ms` rows of precedence table §3; console-views
"record wall-clock, else live counter") and `plan.md` records the same.

**Rationale**: repository precedent — constitution Sync Impact Reports
1.3.0, 2.1.0, and 4.0.0 all leave earlier feature artifacts as an accurate
record of what shipped and point forward from the superseding feature.
Spec FR-015 is the forward pointer.
