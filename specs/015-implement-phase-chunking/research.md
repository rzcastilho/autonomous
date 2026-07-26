# Phase 0 Research: Implement Phase Chunking

**Branch**: `015-implement-phase-chunking` | **Spec**: [spec.md](./spec.md)

Every unknown below was resolved by reading the code and the pinned deps in this
repo — no NEEDS CLARIFICATION survives into Phase 1.

---

## R1 — How is turn exhaustion actually surfaced? (FR-010)

**Decision**: Detect exhaustion from the harness event's **result subtype**
`"error_max_turns"`, captured into a new `%PhaseResult{subtype: String.t() | nil}`
field and exposed as `PhaseResult.exhausted?/1`. Never infer it from error prose.

**Rationale**: `deps/jido_claude/lib/jido_claude/cli/raw_stream.ex:157` maps the
CLI's terminal JSON `{"type":"result","subtype":"error_max_turns"}` to
`%Message{type: :result, subtype: :error_max_turns}`; the mapper
(`deps/jido_claude/lib/jido_claude/mapper.ex:64-70`) then emits a
`:session_failed` event whose payload is
`%{"error" => …, "subtype" => "error_max_turns"}`.
`PhaseResult.reduce/1` currently folds `:session_failed` into
`status: :error, error: payload["error"]` and **discards `"subtype"`** — which is
exactly why the 2026-07-25 production run could only see "an error" and
classified it terminal. Adding `subtype` to the fold is a two-line change at the
one place the contract is already isolated (Constitution I).

**Alternatives considered**:
- *Substring-match the error text* (as `transient?/1` does for server drops).
  Rejected: the marker list is a heuristic tuned for network noise; exhaustion is
  a first-class, deterministic subtype the adapter already carries.
- *Compare `num_turns` against `Config.implement_max_turns/0`.* Rejected:
  `num_turns` is only populated on the `:success` path
  (`mapper.ex:51-61`) — a max-turns result never reaches that clause.

**Consequence**: `PhaseResult.transient?/1` is left **unchanged**. Exhaustion is
classified before the transient-retry ladder, so FR-014 ("other outcomes handled
by existing rules, unchanged") holds by construction.

---

## R2 — What is the task-phase grammar? (FR-001, FR-004)

**Decision**: A task-phase is a line matching
`^##\s+Phase\s+<number>\s*:\s*<title>$`. Its member tasks are every subsequent
checkbox line `- [ ]` / `- [X]` (optionally carrying a `T<digits>` id) up to the
next `##` heading, outside fenced code blocks. Zero such headings ⇒ unstructured
⇒ FR-004 fallback.

**Rationale**: Verified against `.specify/templates/tasks-template.md` and the
five generated task lists in this repo — e.g.
`specs/014-recovery-reconciliation/tasks.md` yields
`Phase 1: Setup`, `Phase 2: Foundational (Blocking Prerequisites)`,
`Phase 3..6: User Story N - …`, `Phase 7: Polish & Cross-Cutting Concerns` —
the exact shape the spec's production observation (quickpoll 001, 5 task-phases)
describes. Three details matter:

1. **Only `##` splits.** `### Tests for User Story 1` / `### Implementation for
   User Story 1` are *inside* a task-phase; splitting on them would shred every
   story into two half-phases.
2. **`## Dependencies & Execution Order`, `## Notes`, `## Implementation
   Strategy` are `##` headings but not task-phases.** Requiring the literal
   `Phase <n>:` prefix excludes them without a blocklist. Their stray checkboxes
   (if any) are then correctly *not* counted as tasks.
3. **Fenced blocks are skipped.** `## Parallel Example: Phase 2 (Foundational)`
   contains a ```` ``` ```` block with lines like `# T002 first (struct shape)`.
   Skipping fences keeps them out of both the task list and the heading scan.

The heading `number` is kept as an **opaque string**, never parsed to an integer:
the spec requires order of appearance to be authoritative under duplicate or
non-sequential numbering, and the template itself emits a literal `Phase N:` for
the Polish section.

**Alternatives considered**:
- *Ask the tasks phase to emit machine-readable metadata (front-matter, JSON
  sidecar).* Rejected: it changes an upstream contract this feature explicitly
  must not touch (FR-008), and every existing task list would become
  unstructured overnight.
- *Split on any `##`.* Rejected — see (1)/(2) above; it silently invents
  task-phases named "Notes".

---

## R3 — Where does the chunk loop live?

**Decision**: A new **`ChunkRunner`** edge module owns the implement loop, driven
by a new **pure `Chunking.next/2`** decision function. `FeatureRunner` delegates
to it for `phase == :implement` and receives back the same
`{outcome, reason, agent}` shape every other phase produces. Each chunk is one
`"phase.run"` signal (`data: %{phase: :implement, scope: …}`) — i.e. one action
execution, one harness session.

**Rationale**: The alternative — looping *inside* `Actions.RunFeaturePhase` —
breaks three existing invariants at once:

- `config :jido_action, default_timeout: :timer.minutes(45)` (config.exs:64)
  bounds **one action**. N chunk sessions inside one action would need an N×
  timeout, and the `FeatureRunner` `AgentServer.call` timeout
  (`@default_phase_timeout`, 50 min) is deliberately kept just above it
  (`feature_runner.ex:33-37`). Per-chunk actions keep both guards meaningful.
- `:telemetry.span([:speckit, :phase], …)` wraps one action call
  (`feature_runner.ex:292`); the console's per-phase cost/outcome cell is folded
  from it. One span over N sessions would collapse the visibility this feature
  exists to add.
- Per-chunk transcripts (FR-026) and per-chunk commits (FR-023a) are runner-side
  concerns — the action has no worktree-commit responsibility today and should
  not gain one.

`Chunking.next/2` staying pure mirrors `Pipeline.next/3`: gate signals (tasks
completed delta, exhaustion, session counts) are extracted upstream and passed
in, so the whole continuation/sweep/ceiling policy is unit-testable with no CLI,
no worktree, and no git (Constitution I + VI).

**Alternatives considered**:
- *Make each task-phase a real `Pipeline` phase.* Rejected outright by FR-008 —
  the seven-step model and its gate semantics must not change.
- *A per-feature chunk GenServer.* Rejected: nothing needs to serialize state
  across processes; the runner is already a supervised `Task` running one
  feature synchronously (Constitution VI — pick the smallest OTP abstraction
  that fits).

---

## R4 — Is scoping a session to one task-phase supported, or a workaround?

**Decision**: Supported. Scope via the `/speckit.implement` command's documented
argument, plus an explicit release from its "all tasks" completion condition.

**Rationale**: `.claude/skills/speckit-implement/SKILL.md` declares
`argument-hint: "Optional implementation guidance or task filter"`, and its
Outline step 5 already parses "**Task phases**: Setup, Tests, Core, Integration,
Polish" and step 6 executes "**Phase-by-phase**". The one thing that fights
chunking is its `## Done When` checklist — "All tasks in tasks.md completed and
marked `[X]`" — which is why FR-005 requires the session be *explicitly
released* from it. The scoped prompt therefore states, in order: the single
task-phase to implement, the prohibition on starting later task-phases, the
`[X]` marking obligation, and the explicit override of the "all tasks" condition.

**Alternatives considered**:
- *Rewrite `tasks.md` to hide later task-phases before each session.* Rejected:
  mutating the source of truth to steer a session is exactly the "invent data to
  paper over a contract" failure Constitution II forbids, and it would corrupt
  the very file resume depends on.

---

## R5 — Per-task-phase commits vs. recovery's boundary-commit parser (FR-023a)

**Decision**: Task-phase boundary commits use the subject
`speckit: <id> implement task-phase <ordinal>/<total> <title>` — deliberately
**not** matching recovery's phase-boundary regex.

**Rationale**: `Recovery.Evidence` (`recovery/evidence.ex:75`) treats
`^speckit: (?<id>\S+) checkpoint after (?<phase>\w+)$` as the authority for "the
newest completed pipeline phase". A task-phase commit that matched it would make
crash recovery believe `implement` had *completed* and resume the feature at
`converge` over a half-built tree. Keeping the shape distinct means the newest
matching boundary stays `…checkpoint after tasks`, so recovery correctly resumes
at `implement` — where FR-003's skip-completed-task-phases rule then makes the
re-entry cheap. No change to `Evidence` is required, which is the point.

**FR-023b is satisfied with zero new code**: `FeatureRunner.handle_worktree/4`
already squashes everything since `merge_base(repo, branch)` into one commit on
`:done` (`feature_runner.ex:349-359`); task-phase commits sit inside that range.
On a non-`:done` terminal the existing `commit/2` path leaves them in place as
the post-mortem trail — exactly what FR-023b asks for.

---

## R6 — Transcript naming vs. the `07-converge.md` fixed path (FR-026)

**Decision**: Chunk transcripts are written as
`06-implement-p<ordinal>-a<attempt>.md` (and `06-implement-sweep-a<attempt>.md`),
i.e. **suffixes on implement's existing step number 6**. Step numbers are never
consumed by chunks. A roll-up `06-implement.md` is written when the implement
step ends.

**Rationale**: `Recovery.Evidence.final_marker?/2` reads the hard-coded path
`<feature_id>/07-converge.md` (`evidence.ex:164`). If chunks incremented the
`step` counter that `FeatureRunner.loop/9` threads
(`feature_runner.ex:252`), converge would land at `10-converge.md` or worse, and
the non-PR done-signal would silently stop being found — a regression in a
different feature's guarantee, invisible until a crash. Suffixing keeps the
pipeline's step numbering a property of the seven-step model (FR-008).

The roll-up also discharges **FR-027**: `Transcripts.render/2` currently prints
status/session/cost/turns/final-text but **not** `PhaseResult.error` or the new
`subtype`, so today an operator reading the transcript cannot tell exhaustion
from a real failure. Both fields are added to the rendered header.

---

## R7 — Progress measurement for the continuation rules (FR-011/012/013)

**Decision**: Progress = the count of `[X]` tasks across the **whole task list**,
sampled immediately before and immediately after each session. A strictly higher
after-count is progress.

**Rationale**: The spec's own assumption ("Task-list completion marks are the
progress signal") plus its "Out-of-scope completions" edge case: a session scoped
to task-phase 3 that also finishes a task-phase 5 task **has** made forward
progress and its work must be respected. Counting only in-scope tasks would
discard that and could push a genuinely-progressing feature into the no-progress
bound. Whole-list counting also makes the fallback path (FR-004) use the same
measure with no special case.

**Alternatives considered**:
- *Trust the session's own prose report of what it completed.* Rejected: the
  file is the source of truth (Constitution II), and a truncated session's final
  message is exactly what is missing when it is cut off mid-edit.

---

## R8 — Session-ceiling default as a formula (FR-013a)

**Decision**: Two config keys, `implement_sessions_per_task_phase` (default `2`)
and `implement_sessions_headroom` (default `4`); the ceiling is
`per_task_phase * task_phase_count + headroom`, resolved at implement-step start
from the freshly parsed plan. The FR-004 fallback path has `task_phase_count = 1`
⇒ ceiling `6`.

**Rationale**: The spec's stated default is "twice the task-phase count plus
four", which is a formula, not a scalar — a fixed number would be simultaneously
too tight for an 8-task-phase feature and far too loose for a 2-task-phase one.
Two scalar keys keep `Config` a set of typed accessors (no callables in config,
no `apply/3` on operator input) while remaining fully overridable.

**Recomputation**: because the plan is re-read before every dispatch (FR-006), a
task list that grows mid-run would change the ceiling. The ceiling is therefore
**resolved once, at implement-step start, and frozen** — otherwise a session that
appends task-phases could raise its own budget without bound, defeating FR-013a's
purpose.

---

## R9 — FR-007a (fail on unchecked tasks) vs. SC-005 (no new failures on
unstructured lists)

**Decision**: FR-007a applies on **both** paths, and the FR-007 sweep is
therefore also dispatched on the FR-004 fallback path before any such failure.

**Rationale**: Read literally, FR-007a ("report success only when every task is
marked complete") and SC-005 ("lists with no task-phase structure produce no new
failures") can collide: an unstructured list whose session left tasks unchecked
succeeds today and would fail under FR-007a. Three facts resolve it in favour of
applying FR-007a everywhere:

1. That "success" is a **false-green** of exactly the class the artifact and
   converge gates were added to close (`pipeline.ex:22-29`) — the feature
   reports done, `converge` runs against a half-built tree, and a PR opens.
   Constitution II makes the loud failure the correct default.
2. The fallback path gains *two* new recovery mechanisms before it can fail:
   FR-004 continuation on exhaustion-with-progress, and the sweep. A run that
   previously limped to a false success now has strictly more chances to reach a
   real one.
3. Lists with **no checkbox tasks at all** (hand-written prose plans) are
   vacuously complete and can never trip FR-007a — so the "old/hand-written
   task list" population SC-005 is written to protect is untouched.

**Residual risk, stated plainly**: a hand-written checkbox list that the model
never fully checks off will now fail where it previously passed. Mitigation is
diagnostic, not silent: the failure reason names the unchecked task ids
(FR-007a), which is precisely the SC-006 diagnosability the feature promises. If
a target repo needs the old behaviour, that is a config knob to add later, not a
default.

---

## R10 — The artifact gate under chunking

**Decision**: `Actions.RunFeaturePhase`'s `:implement` artifact gate
(`implementation_changes?/1`) is evaluated **once, on the implement step's
roll-up**, never per chunk.

**Rationale**: The gate answers "did implement write any code outside
specs/docs?" (`run_feature_phase.ex:123-129, 169-180`). A `Setup` task-phase
that only touches `mix.exs` still passes it, but a legitimately doc-only early
task-phase would trip it and fail the whole feature mid-implement — turning a
false-green guard into a false-red one. Per-chunk, the correct progress signal is
the completed-task delta (R7); the artifact gate keeps its whole-step meaning,
and `Pipeline.next/3` keeps receiving exactly one `:implement` outcome with
exactly the signal map it understands today (FR-008).

---

## R11 — Console surfacing (FR-015..019)

**Decision**: New `[:speckit, :chunk, :start | :stop | :exception]` telemetry
span; `ConsoleReadModel` folds it into a new per-feature `:chunk` slice; the
`phase_strip` implement cell renders a sub-label when `chunk != nil`.
`overlay_last_known_statuses/3` reads the checkpoint's new `implement_chunk`
key for inactive runs (FR-018).

**Rationale**: This is the established path, not a new one:
`ConsoleProjection` already attaches to `Telemetry.events/0` and broadcasts
diffs (`console_projection.ex:56-61`), and `overlay_last_known_statuses/3`
already reconstructs a dead run's phase timeline from checkpoints
(`console_read_model.ex:187-235`). FR-019 ("render exactly as today") is
satisfied structurally: an unstructured feature emits chunk events with
`scope: :whole_list`, which the read model records but the strip does not
render — `chunk` stays visually absent rather than showing `1/1`.

**Alternatives considered**:
- *Have the console poll the worktree's `tasks.md`.* Rejected: the console is an
  observability surface and "MUST NOT become a second source of truth"
  (Constitution, Technology Stack). Telemetry + checkpoint keeps the run state
  authoritative.

---

## R12 — Toolchain / dependency check

**Decision**: No new runtime dependencies, no new OTP processes, no schema or
storage change. Elixir `1.20.2-otp-28` via `mise exec --`; ExUnit; hermetic
tests by default with real-harness coverage behind `--include integration`.

**Rationale**: Everything above composes existing modules (`PhaseResult`,
`PhaseRequest`, `Transcripts`, `Checkpoint`, `Worktree`, `ConsoleReadModel`) plus
two new pure modules and one new edge module. The Technology Stack section of the
constitution requires any new dependency to be justified against it — none is
needed, so none is proposed.
