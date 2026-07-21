# Phase 1 Data Model: Self-Sufficient Resume

Three entities. Only the **Checkpoint record** changes shape on disk; `RunContext`
is new (in-memory + serialized inside the checkpoint); `Feature` is unchanged and
merely *reconstructed* from the record.

## Checkpoint record (extended in place)

Durable per-feature JSON at `<Config.transcript_root>/<feature_id>/checkpoint.json`.
Existing fields kept; two identity fields and one context object added.

| Field | Type (JSON) | Source | New? | Notes |
|-------|-------------|--------|------|-------|
| `feature_id` | string | `feature.id` | — | record key (dir name) |
| `last_phase` | string | `agent.state.phase` | — | atom name; read via `to_existing_atom` + `Pipeline.phase?/1` |
| `status` | string | terminal status | — | `escalated`/`halted`/`failed` (never `done` — done deletes) |
| `reason` | string | `inspect(reason)` | — | diagnostic only |
| `session_id` | string \| null | `agent.state.session_id` | — | |
| `slug` | string | `feature.slug` | **yes** | identity — FR-001 |
| `path` | string | `feature.path` | **yes** | identity (breakdown/artifact path) — FR-001 |
| `context` | object \| absent | captured `RunContext` | **yes** | run-shaping settings — FR-006; absent on old checkpoints |

**Validation / read rules**
- Absent file → `{:error, :no_checkpoint}` (unchanged).
- Present but not a JSON object → `{:error, :corrupt}` (unchanged); never fabricate
  `slug`/`path`/`context` to paper over corruption.
- `slug`/`path` absent on an old checkpoint → resume from checkpoint identity is not
  possible for that record; the explicit/backlog feature (if any) is used, else the
  distinct unknown-feature outcome (edge: unknown-feature).
- `context` absent or partial → fall back to live config for missing keys, logged
  (FR-008).
- Round-trip is lossless for all fields (`read(write(r)) == r` at the string/JSON
  level), per the existing checkpoint contract.

**Lifecycle** — unchanged: written on a non-`:done` terminal, deleted on `:done`.
Extended fields ride the same best-effort write (FR-010).

## RunContext (new)

The set of run-shaping settings captured at run start and reapplied on resume.
Pure in-memory struct; serialized as the checkpoint's `context` object. **Excludes
secrets/credentials by construction** (FR-011) — no field can hold one.

| Field | Type | Config source (fallback) | run/1 opt key |
|-------|------|--------------------------|---------------|
| `pr_workflow` | boolean | `Config.pr_workflow?/0` | `:pr_workflow` |
| `max_concurrency` | pos_integer | `Config.max_concurrency/0` | `:max_concurrency` |
| `budget_usd` | number | `Config.budget_usd/0` | `:budget_usd` |
| `plan_stack` | list(string) | `Config.plan_stack/0` | `:plan_stack` |
| `pr_base` | string | `Config.pr_base/0` | `:pr_base` |
| `pr_remote` | string | `Config.pr_remote/0` | `:pr_remote` |

**Explicitly OUT** (FR-006): `repo` (checkpoint is located via it — circular),
`breakdown_dir` (identity now comes from the checkpoint), model routing, and any
static config.

**Operations** (all pure — Principle I):
- `capture(opts) :: t()` — resolve each field as `Keyword.get(opts, key, Config.<key>())`.
- `to_map(t) :: map()` — JSON-ready string-keyed map for the checkpoint.
- `from_map(map | nil) :: t_partial()` — tolerant decode: absent → empty; partial →
  only present keys populated. Never raises.
- `merge(opts, recorded) :: keyword()` — precedence **explicit opt > recorded > (unset
  ⇒ run/1 falls to Config)**: for each key, if `opts` already has it, keep it; else
  if `recorded` has it, inject it; else leave absent. Returns the run opts to pass to
  `run/1`. Also returns/exposes which keys fell back (for the FR-008 log).

**State transitions**: none (value object).

## Feature (unchanged, reconstructed)

`%Feature{id, slug, path, prereqs, status}`. On an id-only resume it is rebuilt as
`%Feature{id: <id>, slug: <checkpoint.slug>, path: <checkpoint.path>, status:
:pending}` (prereqs default `[]` — irrelevant for a lone resumed feature). No struct
change; `@enforce_keys [:id, :slug, :path]` are exactly the reconstructed fields.
