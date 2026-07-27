# Data Model: Analyze Auto-Remediation Loop

**Feature**: `017-analyze-auto-remediation` | **Phase**: 1

Five entities from the spec, plus the two existing records they extend. Nothing
here is a database row — the orchestrator has no database; durable state is
file-backed (run manifest + per-feature checkpoint + durable transcripts).

---

## E1 — Severity (`SpeckitOrchestrator.Severity`, pure)

The ordered finding vocabulary, promoted from two special cases to a total
order.

| Field | Type | Notes |
|---|---|---|
| — | `:low \| :medium \| :high \| :critical` | ranks 1..4 |
| — | `:unknown` | rank `nil`; matches no threshold (research R3) |

**Operations**

- `rank(severity) :: 1..4 \| nil`
- `parse(String.t() \| atom()) :: {:ok, severity()} \| :error` — case-insensitive;
  `"blocker"` → `:critical` (preserves today's synonym)
- `at_or_above?(severity, threshold) :: boolean()` — `false` for `:unknown`
- `values() :: [severity()]` — the four, in order, for the launch form

**Validation rules**: `parse/1` never raises and never invents a severity. An
unparseable severity is `:unknown`, counted and reported, never dropped from the
attempt record.

**Relationships**: consumed by `AnalyzeResult` (E5) and `Remediation.Settings`
(E2).

---

## E2 — Auto-remediation run settings (`Remediation.Settings`, pure struct)

The three operator-chosen knobs plus the configuration-level model override.
Fixed for the run's lifetime, uniform across its features (FR-010b).

| Field | Type | Default | Constraint |
|---|---|---|---|
| `enabled?` | `boolean()` | `true` | FR-010 |
| `threshold` | `Severity.severity()` | `:high` | one of the four (FR-011) |
| `attempt_limit` | `pos_integer()` | `2` | `1..5` inclusive (FR-004a) |
| `model` | `String.t()` | `Config.model_for(:analyze)` | `"opus" \| "sonnet"` (FR-009a) |

**Operations**

- `validate(map() \| keyword()) :: {:ok, t()} \| {:error, reason}` where
  `reason ∈ {{:invalid_threshold, term}, {:invalid_attempt_limit, term}, {:unknown_model, term}}`
- `from_context(RunContext.t()) :: {:ok, t()} \| {:error, reason}`

**State transitions**: none. The struct is immutable for the run; there is no
mid-run edit path (FR-010b), and `Coordinator.set_cap/2`-style live config
deliberately has no counterpart here.

**Persistence**: as four fields on `RunContext` (E6), string/boolean/integer
only — the JSON-safe shape the manifest and checkpoints already carry.

---

## E3 — Remediation attempt (record, not a struct)

One corrective step targeting a specific set of analyze findings.

| Field | Type | Source |
|---|---|---|
| `attempt` | `pos_integer()` | loop counter, 1-based |
| `limit` | `pos_integer()` | E2 `attempt_limit` |
| `triggering_findings` | `[finding()]` | the verbatim at-or-above-threshold findings from the preceding analyze run |
| `instruction` | `String.t()` | `Remediation.instruction/2` output (pack + findings verbatim) |
| `outcome` | `:ok \| :error` | `PhaseResult` status of the step |
| `cost` | `number()` | `Cost.for_phase(:auto_remediation, result)` |
| `model` | `String.t()` | E2 `model` |

**Where it lives**

- **Durably**: `NN-remediation-a<k>.md` in the worktree's `.speckit_logs/` and
  in the run's `transcript_root` (survives `:done` teardown) — FR-012/FR-012a.
- **In flight**: one entry per attempt prepended to `FeatureAgent.history`
  (`%{phase: :auto_remediation, attempt: k, outcome:, cost:}`), the same fold
  shape every other step uses.
- **As telemetry**: one `[:speckit, :remediation]` span per attempt (E7).

**Invariant**: never overwritten. `k` is monotonic within one feature run and
resets to 1 on the next (FR-015).

---

## E4 — Remediation loop state (per feature run, in memory only)

Lives for the duration of one analyze step. Never a pipeline position (FR-012b),
never restored from a checkpoint (FR-015).

| Field | Type | Notes |
|---|---|---|
| `settings` | `Settings.t()` | E2 |
| `attempts_used` | `non_neg_integer()` | starts at 0 |
| `analyze_runs` | `pos_integer()` | ≥ 1; equals `attempts_used + 1` on a converged or exhausted loop |
| `last_result` | `AnalyzeResult.t() \| nil` | the most recent parse (FR-005) |
| `last_outcome` | `:ok \| :error` | of the most recent analyze run |

**State transitions** — the whole decision surface is
`Remediation.next(state, signals)`; the full table is
`contracts/remediation.md` §2:

```text
                    ┌───────────────────────────────────────────┐
                    ▼                                           │
  analyze run ──► evaluate ──► {:gate, state}  (converged, or   │
      ▲                          below threshold, or disabled,  │
      │                          or attempts exhausted)         │
      │                                                          │
      ├────────── {:remediate, findings, state'} ── attempt ─────┘
      │                                              │
      │                                        (attempt errored)
      │                                              ▼
      │                                    {:failed, :remediation_failed}
      │
      └── breaker tripped between steps ──► {:halted, :breaker}
```

**Invariants**

- `attempts_used <= settings.attempt_limit` always (SC-003).
- The gate is always evaluated against `last_result` (FR-005).
- No transition out of `{:gate, _}` — the loop is entered once per analyze step.

---

## E5 — Analyze result (existing, extended)

`SpeckitOrchestrator.AnalyzeResult` keeps every field and both booleans; it
gains severity-ordered accessors.

| Field | Change |
|---|---|
| `summary`, `findings`, `raw` | unchanged |
| `critical?`, `high?` | **unchanged** — still what the gate reads (SC-007a) |
| `max_severity/1` | NEW — highest recognized severity present, `:unknown` if none recognized, `nil` for no findings |
| `findings_at_or_above/2` | NEW — the verbatim findings matching a threshold, in report order |
| `unknown_severities/1` | NEW — findings whose severity did not parse (research R3) |

**Validation rules**: unchanged. A malformed or absent findings report is still
`{:error, _}` and still a failed analyze phase — it never enters the loop
(spec Edge Cases).

---

## E6 — Run context (existing, extended)

`SpeckitOrchestrator.RunContext` grows from six settings to ten.

| New field | Type | Captured from |
|---|---|---|
| `auto_remediation` | `boolean() \| nil` | `opts[:auto_remediation]` ‖ `Config.auto_remediation?/0` |
| `auto_remediation_threshold` | `String.t() \| nil` | `opts[:auto_remediation_threshold]` ‖ `Config.auto_remediation_threshold/0` |
| `auto_remediation_attempt_limit` | `pos_integer() \| nil` | `opts[…]` ‖ `Config.auto_remediation_attempt_limit/0` |
| `auto_remediation_model` | `String.t() \| nil` | `opts[…]` ‖ `Config.auto_remediation_model/0` |

`to_map/1`, `from_map/1`, `merge/2` and `@keys` each gain the four keys; the
FR-011 exclusion of secrets still holds by construction (boolean/integer/string
only). Resume precedence is the existing rule, unchanged: **explicit opt >
recorded context > live Config**.

---

## E7 — Checkpoint (existing, extended)

One new optional key, written with the same omit-when-absent pattern as
`implement_chunk`:

```json
"analyze_remediation": {
  "attempts_used": 2,
  "limit": 2,
  "threshold": "high",
  "enabled": true
}
```

`last_phase` remains `"analyze"` (FR-012b). A pre-017 checkpoint has no key and
resolves exactly as today. The recorded `attempts_used` is **read-only
provenance for the operator** — no resume path consumes it as a spent budget
(FR-015).

---

## Entity relationships

```text
Config ──defaults──► RunContext (E6) ──validate──► Settings (E2) ──► Loop state (E4)
   ▲                     │                                              │
   │                     └──recorded──► RunManifest, Checkpoint (E7)     │
TriggerLive form                                                        │
                                                                        ▼
AnalyzeResult (E5) ◄──parse── analyze run ◄────────────────────► Attempt (E3)
       │                                                            │
       └── Severity (E1) ──threshold match──────────────────────────┘
```
