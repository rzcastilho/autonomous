# Quickstart: Pre-phase remediation prompt at resume

Validation guide proving the remediation step works end-to-end. Scenarios map to
the spec's user stories, success criteria, and edge cases. See
[data-model.md](./data-model.md) for control flow and
[contracts/resume-remediation.md](./contracts/resume-remediation.md) for the
option/behavior contract.

## Prerequisites

- Toolchain via **mise** (`.tool-versions` pins `1.20.2-otp-28`).
- Hermetic tests only — the `FakeSDK` seam (`:jido_claude, :sdk_module`) plus the
  facade `:runner`/`:executor` seams. No real `claude` CLI, no network.

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors ON — a warning fails
```

## Run the feature's tests

```bash
# Pure request builder (model, permissions, prompt framing, blank handling)
mise exec -- mix test test/speckit_orchestrator/phase_request_test.exs

# The remediation action folds cost/history; error outcome on failure
mise exec -- mix test test/speckit_orchestrator/run_remediation_test.exs

# FeatureRunner: step runs once & before the phase; blank = no step;
# failure stops the resume; transient failure is retried
mise exec -- mix test test/speckit_orchestrator/feature_runner_test.exs

# resume/2: opts threaded; independent of :prompt (FR-010)
mise exec -- mix test test/speckit_orchestrator/resume_test.exs

# Full suite + coverage (pure core target >90%)
mise exec -- mix test --cover
```

## Scenario 1 — Fix issues, then re-run the gate (US1, SC-001, FR-002/003)

**Given** a feature halted at `analyze` on a Critical finding, with a kept
worktree and checkpoint.

**When** resumed with a remediation prompt targeting `analyze`:

```elixir
SpeckitOrchestrator.resume("003",
  from: :analyze,
  remediation_prompt: "Fix the money-type Critical the analyze gate flagged in plan.md."
)
```

**Then** — with the `FakeSDK` `:remediation` scenario driving the step:
- a remediation step executes **first** (assert via the `[:speckit, :phase]`
  span with `phase: :remediation`, and a `00-remediation.md` transcript),
- **then** `analyze` runs and evaluates the artifacts as remediation left them,
- the step is invoked **exactly once** and **before** the phase (assert ordering
  via captured telemetry / agent `history`).

## Scenario 2 — Resume directly, no remediation (US2, SC-002, FR-004)

**When** resumed with no (or blank) remediation prompt:

```elixir
SpeckitOrchestrator.resume("003", from: :analyze)                     # absent
SpeckitOrchestrator.resume("003", from: :analyze, remediation_prompt: "   ")  # blank
```

**Then** zero remediation steps run — no `remediation.run` signal, no
`00-remediation.md`, no extra `Ledger` spend — and the target phase executes
directly, byte-identical to today's resume.

## Scenario 3 — No leak past the target phase (US3, SC-003, FR-005)

**Given** a resume with a remediation prompt targeting `analyze` that then
advances to `implement`.

**Then** the remediation step precedes **only** `analyze`; no remediation step
precedes `implement` or any later phase (assert: exactly one `phase:
:remediation` span across the whole run).

## Scenario 4 — Remediation fails → phase does NOT run (SC-005, FR-006)

**Given** the `FakeSDK` `:remediation_error` scenario (a genuine, non-transient
failure, or a transient one that persists past `Config.phase_max_retries()`).

**Then** the target phase is **not** executed; the feature finalizes `:failed`,
the worktree is retained, and the caller is notified — the operator sees the
failure rather than the phase running on unremediated artifacts.

**And** a `:remediation_transient_once` scenario (one transient drop, then
success) is auto-retried and proceeds — retry parity with a phase (FR-006).

## Scenario 5 — Model override (FR-011)

```elixir
SpeckitOrchestrator.resume("003", from: :analyze,
  remediation_prompt: "…", remediation_model: "opus")
```

**Then** the remediation request carries `opus`; the `analyze` phase's own model
routing is unchanged. An unknown alias returns `{:error, {:unknown_model, …}}`
and starts no run.

## Scenario 6 — Independent of the in-phase note (FR-010)

```elixir
SpeckitOrchestrator.resume("003", from: :plan,
  prompt: "Prefer the smaller migration.",          # feature-004 in-phase note
  remediation_prompt: "First delete the dead column.")  # this feature
```

**Then** the remediation step runs its own execution with the remediation text,
**and** the `plan` phase's own prompt still carries the feature-004 operator note
appended — neither suppresses the other.

## Expected outcomes checklist

- [X] SC-001 — non-blank prompt ⇒ exactly one step, before the phase
- [X] SC-002 — blank/absent ⇒ zero steps, zero extra cost
- [X] SC-003 — no step precedes any phase after the target
- [X] SC-004 — a gate halt becomes a corrected re-run in a single `resume/2` call
- [X] SC-005 — a failed step never lets the phase run on unremediated artifacts
- [X] SC-006 — every step leaves a telemetry span + durable transcript
- [X] `mise exec -- mix test` green; `--cover` keeps pure core >90%
