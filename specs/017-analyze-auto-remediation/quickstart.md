# Quickstart: validating the analyze auto-remediation loop

Runnable validation for `017-analyze-auto-remediation`. Every scenario below is
hermetic unless it is explicitly marked **integration**. Details of shapes and
rules live in [`data-model.md`](./data-model.md) and [`contracts/`](./contracts/);
this file is how you *run* the thing.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

Toolchain is pinned to `1.20.2-otp-28`; the bare shell PATH is a stale global
Elixir. Every command goes through `mise exec --`.

## The whole suite

```bash
mise exec -- mix test
mise exec -- mix test --cover                    # pure core must stay >90%
mise exec -- mix test --include integration      # opt-in real-harness coverage
```

---

## US1 — self-heal without waking a human (P1)

**What proves it**: a feature whose analyze reports one High finding on the
first pass and none on the second reaches `:done` with no operator input, and a
remediation step ran between the two analyze runs.

```bash
# pure decision surface — the table in contracts/remediation.md §2
mise exec -- mix test test/speckit_orchestrator/remediation_test.exs
mise exec -- mix test test/speckit_orchestrator/severity_test.exs

# the loop end to end against a scripted fake agent (no CLI, no worktree)
mise exec -- mix test test/speckit_orchestrator/analyze_runner_test.exs
```

Expected:

- `Remediation.next/2` returns `{:remediate, [finding], state}` on pass 1 and
  `{:gate, state}` on pass 2 (rows 7 then 5).
- `AnalyzeRunner.run/1` returns an agent whose `last_signals` come from the
  **second** analyze run — `%{critical?: false, high?: false}` — so
  `Pipeline.next(:analyze, :ok, …)` yields `{:cont, :implement}` (FR-005, AS-2).
- Below-threshold-only findings make **no** harness call beyond the first
  analyze run (FR-016, SC-004) — asserted by call-count on the fake agent.
- Transcripts written: `05-analyze-a1.md`, `05-remediation-a1.md`,
  `05-analyze-a2.md`, `05-analyze.md` (the last holding the clean run) —
  contracts/analyze_loop.md §4.

**Integration** (drives the real CLI against a scratch target repo):

```bash
mise exec -- mix test test/speckit_orchestrator/integration/analyze_loop_test.exs --include integration
```

---

## US2 — give up safely with a full history (P2)

**What proves it**: a feature whose analyze reports the same at-or-above finding
every pass attempts remediation exactly `attempt_limit` times, then reaches the
same terminal state it would have reached with the loop disabled, worktree kept,
every attempt recorded.

```bash
mise exec -- mix test test/speckit_orchestrator/analyze_runner_test.exs
mise exec -- mix test test/speckit_orchestrator/feature_runner_test.exs
mise exec -- mix test test/speckit_orchestrator/checkpoint_test.exs
```

Expected:

- Exactly `n` remediation attempts for limit `n`, never `n+1` (SC-003) —
  asserted on the fake agent's signal log, and independently on the count of
  `NN-remediation-a*.md` files.
- Terminal reason is `{:escalated, {:high_findings, :auto_remediation_exhausted}}`
  (or `{:halted, {:critical_finding, :auto_remediation_exhausted}}`) — FR-006,
  contracts/remediation.md §4.
- A remediation step that errors stops the loop **immediately** with
  `{:failed, :remediation_failed}` and does not consume the remaining attempts
  (FR-008, AS-2).
- A breaker tripped mid-loop halts between steps with `{:halted, :breaker}`; the
  in-flight step still finished and is still accounted (FR-009, AS-3).
- The checkpoint carries `analyze_remediation: %{attempts_used: n, …}` with
  `last_phase: "analyze"` unchanged (FR-012b).
- Findings that got *worse* between attempts (High → Critical) are decided by
  the **final** run: `:halted`, not `:escalated` (spec Edge Cases).

Fresh budget on a human-initiated re-run (FR-015):

```bash
mise exec -- mix test test/speckit_orchestrator/resume_test.exs
```

The resumed run starts at `attempts_used == 0` even though the checkpoint
records an exhausted budget.

---

## US3 — launch with or without the loop (P3)

**What proves it**: the same feature behaves three different ways under three
launch configurations, and an unspecified launch defaults to on.

```bash
mise exec -- mix test test/speckit_orchestrator/remediation_test.exs      # validate/1
mise exec -- mix test test/speckit_orchestrator/run_context_test.exs      # capture/round-trip
mise exec -- mix test test/speckit_orchestrator/web/trigger_live_test.exs # the launch form
```

Expected:

- No configuration → `enabled? == true`, `threshold == :high`,
  `attempt_limit == 2` (AS-1).
- `threshold: :critical` with a High finding → no remediation, escalates as
  today (AS-2).
- `auto_remediation: false` → indistinguishable from pre-017: one analyze run,
  one transcript named `05-analyze.md`, gate reason a bare atom, spend equal to
  a single analyze phase (AS-3, SC-007a).
- `threshold: :medium` with a Medium finding → remediation runs (AS-5) — a
  severity that carries no behaviour today.
- `attempt_limit: 0` or `6`, or `threshold: :urgent` → the run is **refused at
  launch** with `{:error, {:preflight, [{:invalid_attempt_limit, 0}]}}` and
  starts no work (AS-4, FR-011). No clamping, no silent default.
- A previous run launched with the loop off does not change the next launch's
  default (AS-6, FR-010c).
- Changing settings while a run is in progress affects only later runs (AS-7) —
  the in-flight run reads its own recorded `RunContext`, never live `Config`.

### By hand, in the console

```bash
mise exec -- mix phx.server
# open http://127.0.0.1:4000/trigger
```

- The three controls show `on` / `High` / `2` untouched (AS-8); starting without
  touching them produces a run with exactly those settings.
- Entering `7` in the attempt limit and pressing Start shows a field error
  naming the setting and starts nothing (AS-9, FR-010e).
- Toggling the switch off dims the other two controls.
- Re-opening `/trigger` after a run launched with the loop off still shows the
  configured defaults (FR-010f).

### By hand, in `iex`

```bash
mise exec -- iex -S mix
```

```elixir
SpeckitOrchestrator.run(auto_remediation: true, auto_remediation_threshold: :medium,
                        auto_remediation_attempt_limit: 3)

SpeckitOrchestrator.print_status()     # phase strip shows "analyze / attempt 1/3"
SpeckitOrchestrator.Telemetry.attach_default_logger()   # one line per attempt
```

---

## Observability (FR-013) and history (SC-005)

```bash
mise exec -- mix test test/speckit_orchestrator/console_read_model_test.exs
mise exec -- mix test test/speckit_orchestrator/web/escalations_live_test.exs
```

Expected: an in-flight loop renders `attempt k/n` under the analyze cell within
the existing 5 s window; a feature handed over after exhaustion shows
`auto-remediation: n/n attempts exhausted (threshold high)` with each attempt's
transcript reachable from the transcripts view.

---

## Governance (FR-017)

The constitution amendment is part of this feature, not a follow-up. After
implementation:

```bash
rtk git diff .specify/memory/constitution.md
```

Verify against [`contracts/constitution-amendment.md`](./contracts/constitution-amendment.md) §6:
version reads `1.2.0`, the Sync Impact Report is prepended, the prior report is
retained, and no principle other than V has changed text.
