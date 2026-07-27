# Contract: telemetry + console surfaces

Covers FR-013 (an in-progress loop is observable), FR-010d/FR-010e (launch
controls and their validation) and SC-005 (a handed-over feature arrives with
its history).

## 1. Events

### New — one span per remediation attempt

```text
[:speckit, :remediation, :start | :stop | :exception]
```

| Key | `:start` | `:stop` adds | `:exception` adds |
|---|---|---|---|
| `feature_id` | ✓ | | |
| `phase` | `:analyze` (the step the loop belongs to) | | |
| `attempt` / `limit` | ✓ | | |
| `threshold` | ✓ (atom) | | |
| `findings_count` | ✓ — how many were at or above threshold | | |
| `max_severity` | ✓ | | |
| `model` | ✓ | | |
| `outcome` | | `:ok \| :error` | |
| `cost` | | number | |
| `kind` / `reason` | | | ✓ |

Measurements: `%{system_time}` / `%{duration}`, i.e. whatever
`:telemetry.span/3` supplies — same as the phase and chunk spans.

### Extended — the analyze phase span

`[:speckit, :phase, :start|:stop]` for `phase: :analyze` gains `attempt` and
`limit` in its metadata **only when the loop is enabled**. With the loop off the
metadata map is byte-identical to today (FR-010, SC-007a).

### Registration

`Telemetry.events/0` gains the three new names; `Telemetry.remediation_span/0`
returns `[:speckit, :remediation]`. `attach_default_logger/0` gains one clause
logging attempt/limit/outcome/cost.

## 2. Console read model

`ConsoleReadModel` folds the new events into the existing per-feature slice —
the same shape the chunk slice uses, so no new rendering concept is introduced:

```elixir
feature.remediation :: %{attempt: pos_integer(), limit: pos_integer(),
                         threshold: atom(), findings: non_neg_integer(),
                         outcome: :ok | :error | nil} | nil
```

| Event | Fold |
|---|---|
| `[:speckit, :remediation, :start]` | set `feature.remediation`; push feed entry `"auto-remediation attempt k/n — N findings ≥ high"` |
| `[:speckit, :remediation, :stop]` | add `cost` to `feature.spend`; push feed entry with the outcome |
| `[:speckit, :remediation, :exception]` | mark `outcome: :error`; push an `:error` feed entry |
| `[:speckit, :feature, :terminal]` | clear `remediation: nil` (same as `chunk: nil`) |

**No double counting**: remediation cost arrives only on
`[:speckit, :remediation, :stop]`; analyze cost only on
`[:speckit, :phase, :stop]`. The two never describe the same harness run, so
neither needs the `chunk_cost_seen` guard 015 required.

A finding with an unrecognized severity pushes one `:warn` feed entry naming the
value (research R3) — reported, not silently dropped.

## 3. Phase strip sub-label (FR-013)

`core_components.phase_strip/1` already renders a sub-label under the
`implement` cell for chunk position. The same slot renders under the `analyze`
cell when `@remediation` is present:

```text
  analyze
  attempt 1/2
```

Reuses the existing `phase-chunk-sublabel` styling (renamed to
`phase-sublabel`, with the chunk call site updated) — no new CSS concept, no
new asset. Absent when no loop is running, so an unaffected feature's strip is
pixel-identical to today.

## 4. Launch form (`/trigger`, FR-010d, FR-010e, FR-010f)

Three controls, placed alongside the existing stacked-PR toggle:

| Control | Type | Pre-filled from |
|---|---|---|
| Auto-remediation | checkbox (switch, same markup as the PR toggle) | `Config.auto_remediation?/0` |
| Severity threshold | `<select>` over `Severity.values/0` | `Config.auto_remediation_threshold/0` |
| Attempt limit | `<input type="number" min="1" max="5">` | `Config.auto_remediation_attempt_limit/0` |

Behaviour:

- Threshold and limit controls are **disabled** (and visually dimmed) while the
  switch is off — the settings are meaningless then, and FR-010's promise is
  that off is exactly today's behaviour.
- On start, the three values go through `Remediation.Settings.validate/1`
  **before** `SpeckitOrchestrator.run/1` is called. An error assigns a
  field-level message naming the offending setting
  (`data-error="auto-remediation-limit"` / `="auto-remediation-threshold"`) and
  **no run starts** (FR-010e).
- Accepted values are passed as run opts only. Nothing is written to application
  env, so the next mount of the form still shows the configured defaults
  (FR-010f, SC-007a's "leaves the next run's default untouched").
- `Config.auto_remediation_model/0` is **not** a form control (FR-009a) — it is
  a configuration-level knob, overridable per run by a caller of `run/1`.

## 5. Escalations surface (SC-005)

`EscalationsLive` reads the feature's checkpoint already. When
`analyze_remediation` is present it renders one line above the resume controls:

```text
auto-remediation: 2/2 attempts exhausted (threshold high)
```

with the attempt transcripts linked through the existing transcripts view, so a
reviewer sees what was tried without opening raw agent logs.

## 6. Latency

The existing broadcast-on-event path plus the 2 s reconcile tick already meet
"visible within 5 s"; no new timer, no new subscription, no new topic.
