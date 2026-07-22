# Phase 1 Data Model: Control Plane UI Redesign

This is a presentation-only feature (FR-020): it introduces **no new domain data**.
The "model" here is (a) the **design-system token set** the redesign encodes, and
(b) the **existing view-model shapes** the LiveViews already read — restated to fix
their contract so the restyle does not alter them. Source-of-truth colors/metrics
come from `docs/control-plane-design-reference/` (FR-019); the full token table lives
in [contracts/design-system.md](./contracts/design-system.md).

## A. Design-system tokens (new)

### Theme palette

| Token | Value | Use |
|---|---|---|
| `--bg` | `#0b0d12` | App background |
| `--panel` | `#0e1016` | Sidebar / cards / bars |
| `--border` | `#1c212c` | Hairline dividers |
| `--border-strong` | `#232936` | Scrollbar thumb, emphasized edges |
| `--text` | `#e6e9f0` | Primary text |
| `--muted` | `#5a6274` | Labels, secondary text |
| `--accent` | `#7c5cff` | Brand accent, active nav, primary action |
| `--accent-2` | `#4b2fd6` | Logo gradient end |
| `--link` | `#a78bfa` / hover `#c4b5fd` | Links |

### Status palette (replaces current `CoreComponents.@palette` colors)

| Status | Label | New color (reference) | Old color (removed) |
|---|---|---|---|
| `pending` | Pending | `#64748b` | `#9ca3af` |
| `blocked` | Blocked | `#475569` | `#6b7280` |
| `running` | Running | `#38bdf8` | `#3b82f6` |
| `escalated` | Escalated | `#fbbf24` | `#f59e0b` |
| `halted` | Halted | `#fb7185` | `#ef4444` |
| `failed` | Failed | `#f43f5e` | `#991b1b` |
| `done` | Done | `#34d399` | `#22c55e` |

**Invariant**: exactly one palette map (`CoreComponents.@palette`) holds these; every
status color in the shell, cards, table, DAG, drawer, and legend derives from it
(FR-010, SC-001, SC-002). Atom keys and labels are unchanged — only hex values change.

### Typography

| Token | Family | Weights | Source |
|---|---|---|---|
| `--font-sans` | IBM Plex Sans, system-ui, sans-serif | 400/500/600/700 | self-hosted woff2 |
| `--font-mono` | IBM Plex Mono, monospace | 400/500/600 | self-hosted woff2 |

Self-hosted under `priv/static/fonts/`, declared via `@font-face`; **no** runtime font
CDN request (FR-021).

### Layout metrics (from reference)

| Token | Value | Use |
|---|---|---|
| Sidebar width | `236px` (`flex: 0 0 236px`) | Fixed left nav |
| Logo mark | `30×30` rounded `8px`, `#7c5cff→#4b2fd6` gradient, inner rotated square | Branding |
| Two-column collapse | `@media (max-width: 1120px)` → single column | Mission Control feed |
| Radii / spacing | per design-system.md token table | Cards, pills, buttons |

## B. Existing view-models (unchanged — restated to freeze the contract)

These shapes are already produced by the LiveViews / helpers and MUST be consumed,
not modified (FR-020). The redesign changes only their rendering.

### Shell run-view — `Layouts.run_view/0`

```text
%{active?: boolean, title: string, mode: :stacked_pr | :parallel_waves,
  committed: float, reserved: float, budget: float, tripped?: boolean, clock: string}
```
Rendered by the top bar; `active? == false` → "no active run" state (FR-004).

### Shell context / nav — `Layouts.context/0`, `nav_items/0`, `escalations_count/0`

```text
context :: %{repo, cli_auth, runtime}            # target-repo / connection status (FR-001)
nav_items :: [{path, label}]                     # six fixed destinations (FR-001)
escalations_count :: non_neg_integer             # sidebar badge (FR-002)
```

### Feature view-model (Mission Control rows, DAG nodes, drawer)

Per feature, as already surfaced by `Coordinator.status/1.per_feature`:
```text
%{status: Feature.status(), phase progress (per-phase state map),
  elapsed_ms | nil, spend | nil, prereqs, slug, id}
```
Drives: status card counts (FR-005), backlog table row (FR-006), DAG node (FR-009),
drawer timeline/summary (FR-014). Phase order is `Pipeline.phases/0` (seven cells).

### Ledger snapshot — `Ledger.snapshot/1`

```text
%{committed, reserved, budget, tripped?}         # cost gauge (FR-003) + breaker chip
```

### Escalation card model

Per escalated/halted feature (already available via checkpoint + run context):
```text
last_phase, status, session_id, reason, run_context (values),
clarification question(s)/options                # FR-011
```
Missing field → neutral placeholder, not an error (Edge Cases).

## C. State transitions

None. Feature lifecycle statuses and their transitions are owned by the pure core and
are **unchanged**. The redesign only re-colors and re-lays-out their display.
