# Contract: checkpoint + run-context extensions

Two existing durable records gain fields. Neither gains a new file, a new
location, or a new lifecycle.

## 1. `RunContext` — four new settings (FR-010b, FR-010c)

```elixir
defstruct pr_workflow: nil, max_concurrency: nil, budget_usd: nil,
          plan_stack: nil, pr_base: nil, pr_remote: nil,
          auto_remediation: nil,
          auto_remediation_threshold: nil,
          auto_remediation_attempt_limit: nil,
          auto_remediation_model: nil
```

| Key | JSON type | Default source |
|---|---|---|
| `auto_remediation` | boolean | `Config.auto_remediation?/0` (`true`) |
| `auto_remediation_threshold` | string | `Config.auto_remediation_threshold/0` (`"high"`) |
| `auto_remediation_attempt_limit` | integer | `Config.auto_remediation_attempt_limit/0` (`2`) |
| `auto_remediation_model` | string or null | `Config.auto_remediation_model/0` (`nil` → analyze's model) |

- `capture/1`, `to_map/1`, `from_map/1` and `@keys` each gain the four keys.
- The threshold is stored as a **string** (`"high"`), never an atom — these maps
  are JSON-encoded into the manifest and checkpoints, and `String.to_atom/1` on
  file-sourced content is banned repo-wide. `Remediation.Settings.validate/1` is
  the single normalization point (research R4).
- `merge/2` precedence is unchanged: **explicit opt > recorded > live Config**,
  with fallbacks logged.
- FR-011's "no secrets by construction" still holds: boolean, integer, string
  only.

**Consequence for resume** (FR-010b): a resumed run reapplies the recorded
settings, so a run launched with the loop off resumes with it off, without the
operator re-declaring it.

**Consequence for a new run** (FR-010c): nothing is written back to application
env at launch. `TriggerLive` passes the three values as opts and stops there —
the same rule the `pr_workflow` toggle learned the hard way, documented in
`TriggerLive.start_opts/1`.

## 2. `Checkpoint` — one new optional key (FR-012b)

```json
{
  "feature_id": "003",
  "last_phase": "analyze",
  "status": "escalated",
  "reason": "{:high_findings, :auto_remediation_exhausted}",
  "session_id": "…",
  "slug": "…",
  "path": "…",
  "context": { "…": "…", "auto_remediation": true,
               "auto_remediation_threshold": "high",
               "auto_remediation_attempt_limit": 2,
               "auto_remediation_model": null },
  "analyze_remediation": {
    "attempts_used": 2,
    "limit": 2,
    "threshold": "high",
    "enabled": true
  }
}
```

Rules:

- Written by the same `Checkpoint.write/1` call already made, via a
  `maybe_put_analyze_remediation/2` clause identical in shape to
  `maybe_put_implement_chunk/2`. Absent when no loop ran.
- `last_phase` stays `"analyze"`. The loop is **not** a pipeline position
  (FR-012b) — resume, `Recovery.reconcile_run/2` and
  `resolve_start_phase/2` behave exactly as they do today.
- A pre-017 checkpoint has no key and reads unchanged.
- `status: "in_progress"` boundary checkpoints (written after a *successful*
  analyze step) carry the key too, so a crash after a converged loop still
  records what was self-healed.

### `attempts_used` is provenance, never budget (FR-015)

No read path consumes `attempts_used` as a spent budget. `resume/2`,
`resume_run/1` and `resolve/1` all start the loop at `attempts_used == 0` for
the new feature run. The recorded number exists so an operator (and the
escalations view) can see what was already tried — SC-005.

## 3. Run manifest

Unchanged in shape. It already records the run's `context` verbatim, so the four
new settings travel into it for free and appear in `Coordinator.status/0`'s
`:context` — which is what the console status bar reads (never live `Config`).

## 4. Config keys

```elixir
config :speckit_orchestrator,
  auto_remediation: true,
  auto_remediation_threshold: :high,
  auto_remediation_attempt_limit: 2,
  auto_remediation_model: nil,
  cost_estimates: %{
    # …existing…
    auto_remediation: 1.26,   # NEW — runs on the analyze model (FR-009b, SC-008)
    remediation: 0.95         # NEW — closes a pre-existing 0.0 hole (research R6)
  }
```

Accessors on `Config`: `auto_remediation?/0`, `auto_remediation_threshold/0`,
`auto_remediation_attempt_limit/0`, `auto_remediation_model/0`. Each is a plain
`get/2` with the default above — no validation there; validation is
`Remediation.Settings.validate/1`'s job and happens at the launch boundary
(FR-011).
