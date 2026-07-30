# Phase 1 Data Model: Reconcile the console with the design constitution

**Feature**: `020-reconcile-console-design`

This feature adds no persisted state. It touches no Mnesia table, defines no
schema version, and reads no run state it does not already read — SC-009 requires
every view to keep presenting exactly what it presents today. The "entities"
below are therefore **design-time and test-time** structures: the token set, the
status transport, and the two verification artifacts.

Where an entity already exists in the tree, its current shape is given alongside
the reconciled one so the delta is unambiguous.

---

## 1. Design token

A named value from `docs/design-constitution.md` with exactly one definition and
one contract role.

**Representation.** A CSS custom property declared in the single `:root` block at
the head of `priv/static/assets/console.css`. That block is the only region of any
console source in which a color, radius, font-size, or spacing literal may appear.

**Fields**

| Field | Type | Notes |
|---|---|---|
| `name` | CSS custom-property ident | Contract name verbatim for §II colors; role-named for radius/type/spacing |
| `value` | CSS value | Contract value verbatim where the contract fixes one |
| `family` | `surface \| border \| text \| accent \| status \| radius \| type \| spacing \| derived` | Determines which role rules may consume it |
| `role` | prose | The contract's stated use; the basis for every re-pointing decision |

**Validation rules**

- **V-T1** Every §II token exists under its contract name with its contract
  value (24 tokens: 4 surface, 4 border, 4 text, 5 accent, 7 status). *(FR-001,
  SC-001)*
- **V-T2** No token name holds a value belonging to a different contract token.
  This is the specific hazard the amendment recorded: shipped `--border` holds
  `--border-subtle`'s value and shipped `--border-strong` holds `--border`'s.
  *(FR-001, SC-001)*
- **V-T3** No token is added for a value the contract already fixes under another
  name. `--muted`, `--accent-2`, `--link`, `--link-hover` are **retired**, not
  renamed — their use sites are re-pointed by role (see §2).
- **V-T4** A `derived` token exists only where the contract states a literal in
  prose rather than in its token table (scrim, shadows, accent glow, primary
  gradient, selection, reserved hatch). Each cites its contract section.
- **V-T5** No type token is below `10px`; no token used for prose is below
  `11px`. *(FR-007)*

**Token families and their members**

| Family | Members |
|---|---|
| surface | `--bg` `--panel` `--card` `--raised` |
| border | `--hairline` `--border-subtle` `--border` `--border-strong` |
| text | `--text` `--text-secondary` `--text-muted` `--text-faint` |
| accent | `--accent` `--accent-light` `--accent-hover` `--accent-deep` `--accent-shadow` |
| status | `--done` `--running` `--escalated` `--halted` `--failed` `--pending` `--blocked` |
| radius | `--r-pip` `--r-chip` `--r-control` `--r-input` `--r-card` `--r-panel` `--r-dot` |
| type | `--fs-kpi` `--fs-subject` `--fs-title` `--fs-card-title` `--fs-section` `--fs-transcript` `--fs-body` `--fs-meta` `--fs-eyebrow` |
| spacing | `--sp-4` `--sp-6` `--sp-8` `--sp-10` `--sp-12` `--sp-14` `--sp-18` `--sp-20` `--sp-22` (2px grid) |
| derived | `--scrim` `--shadow-drawer` `--shadow-toast` `--glow-accent` `--gradient-primary` `--selection` `--hatch-reserved` |
| family (fonts) | `--font-sans` `--font-mono` *(already correct; unchanged)* |

---

## 2. Token re-pointing map

Not a runtime entity — the recorded decision table that makes the migration
auditable. One row per retired token, resolved **by role** at each use site
(research §1a). Site counts are the measured baseline.

| Retired token | Value | Sites | Resolves to, by role |
|---|---|---|---|
| `--border` | `#1c212c` | 10 | row divider inside a card → `--hairline`; structural region divider → `--border-subtle`; card/panel border → `--border` *(new value `#232936`)*; interactive → `--border-strong` |
| `--border-strong` | `#232936` | 40 | same four-way role split; most sites are card borders → `--border`, secondary-button/interactive → `--border-strong` *(new value `#2a3142`)* |
| `--muted` | `#5a6274` | 42 | uppercase eyebrow / mono metadata → `--text-faint`; description or secondary label → `--text-muted`; value or body → `--text-secondary` |
| `--accent-2` | `#4b2fd6` | 4 | → `--accent-deep` (`#5a3fe0`) |
| `--link` | `#a78bfa` | 3 | → `--accent-light` |
| `--link-hover` | `#c4b5fd` | 1 | → `--accent-hover` |

**Validation rule**

- **V-M1** Every row's site count reaches zero: no `var(--muted)`,
  `var(--accent-2)`, `var(--link)`, or `var(--link-hover)` reference survives,
  and every `var(--border)` / `var(--border-strong)` reference that survives does
  so because its role matches the contract's meaning for that name, not because
  the name was left alone. *(FR-006; verdict recorded per site in the inventory)*

---

## 3. Status

One of the contract's seven run states. Owns exactly one color, used identically
in every representation.

**Members.** `done` `running` `escalated` `halted` `failed` `pending` `blocked`.

**Domain mapping.** `SpeckitOrchestrator.Feature.status/0` also has
`:never_started`, which the contract does not name. It renders as `blocked` — the
contract status whose meaning it shares — rather than introducing an eighth color
(spec assumption; research §2).

**Representations that must resolve to the one definition** *(FR-003, SC-003)*

| Representation | Surface |
|---|---|
| status dot | mission control, escalations, event feed |
| chip / pill | topbar, backlog table, runs table, drawer |
| phase pip | phase strip (mission control, DAG node, drawer) |
| DAG node border | pipeline DAG |
| timeline node | feature drawer, run detail |
| gauge band | topbar cost gauge |
| legend swatch | pipeline DAG legend |

**Transport (current → reconciled)**

| | Current | Reconciled |
|---|---|---|
| Elixir shape | `@palette :: %{atom => {label, hex}}` in `CoreComponents` | `@labels :: %{atom => label}` — **no color** |
| Accessor | `palette/0` → `{label, color}` | `label/1` → prose; `status_class/1` → canonical status string (folds `never_started → "blocked"`) |
| Markup | `style="background-color: #{color}20; …"` | `data-status={status_class(s)}` |
| Color source | Elixir tuple + 33 CSS literals + `escalations_live.status_color/1` | one `[data-status="…"]` rule set in the token-consuming stylesheet |

**Validation rules**

- **V-S1** Exactly one definition per status, in the token block; zero copies in
  server-rendered code, including value-identical ones. *(FR-003)*
- **V-S2** No server-rendered markup emits a color, alpha, or gradient for a
  status — only the status name. *(FR-004a)*
- **V-S3** Chip fill is the status color at `1a`; chip border at `40`. Header
  wash at `0d`. Active fill at `22`. No other suffix appears. *(FR-009)*
- **V-S4** A status color appears on no non-status element. Health indicators,
  validation refusals, toast borders, and PR/artifact blocks are non-status.
  *(FR-012; research §4a–4c)*
- **V-S5** `scPulse` attaches only at `data-status="running"`. *(FR-015)*

---

## 4. Console surface

A rendered operator view or shared component subject to the contract. Fixed,
enumerable set — the guard's input domain and the inventory's row key.

| Surface | Path | LOC |
|---|---|---|
| stylesheet | `priv/static/assets/console.css` | 2050 |
| shared primitives | `lib/speckit_orchestrator/web/components/core_components.ex` | 203 |
| feature drawer | `lib/speckit_orchestrator/web/components/feature_drawer.ex` | 210 |
| layout helpers | `lib/speckit_orchestrator/web/components/layouts.ex` | 95 |
| app chrome | `lib/speckit_orchestrator/web/components/layouts/app.html.heex` | 99 |
| document shell | `lib/speckit_orchestrator/web/components/layouts/root.html.heex` | 33 |
| mission control | `lib/speckit_orchestrator/web/live/mission_control_live.ex` | 295 |
| pipeline DAG | `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` | 390 |
| trigger run | `lib/speckit_orchestrator/web/live/trigger_live.ex` | 465 |
| escalations | `lib/speckit_orchestrator/web/live/escalations_live.ex` | 569 |
| runs | `lib/speckit_orchestrator/web/live/runs_live.ex` | 202 |
| run detail | `lib/speckit_orchestrator/web/live/run_detail_live.ex` | 314 |
| transcripts | `lib/speckit_orchestrator/web/live/transcripts_live.ex` | 235 |
| configuration | `lib/speckit_orchestrator/web/live/config_live.ex` | 195 |

**Out of scope for the visual contract** (spec assumption): `Report.format_status/1`
(iex table), `docs/**`, and `priv/static/assets/app.js` (7 lines, 0 color
literals, 0 style attributes — measured). The vendored script remains in the
guard's input domain so it cannot become a hiding place.

---

## 5. Violation *(compliance check output)*

Produced by `SpeckitOrchestrator.Web.DesignContract.scan/1`. Pure struct; no
process, no I/O.

```
%Violation{
  rule:    atom(),        # see contracts/design-guard.md for the closed set
  path:    String.t(),    # console surface, repo-relative
  line:    pos_integer(),
  excerpt: String.t()     # the offending text, trimmed
}
```

**Validation rules**

- **V-V1** `scan/1` is a pure function of a `%{path => source}` map. It performs
  no file I/O, no network call, and no shell out. *(FR-024, SC-008)*
- **V-V2** Every violation names `path` and `line`. A rule that cannot localise
  its finding is not admitted to the rule set. *(FR-023)*
- **V-V3** A clean tree yields `[]`. *(SC-007)*
- **V-V4** Each of the four guarded divergence classes — color literal, duplicate
  status value, unknown keyframe, mechanically detectable §VIII prohibition —
  yields at least one violation when injected. Proven against crafted source
  strings, not by mutating the tree. *(SC-007)*

---

## 6. Compliance inventory row

The committed artifact (`compliance-inventory.md`, this spec dir) recording every
contract rule the guard cannot decide. It is the evidence behind each "0
remaining" claim outside the guard's reach.

| Field | Notes |
|---|---|
| `surface` | one of §4 |
| `element` | selector, component function, or HEEx locus — precise enough to re-check |
| `rule` | the contract citation (`§III mono rule`, `§VIII status-color-decorative`, `§VII.4 ranking`, …) |
| `verdict` | `compliant` \| `remediated` \| `divergence` |
| `note` | for `remediated`, what changed; for `divergence`, the Complexity Tracking reference |

**Validation rules**

- **V-I1** Every contract rule this feature claims is assigned to **exactly one**
  means — guard or inventory — with zero unassigned and zero claimed on assertion
  alone. *(FR-026, FR-027, SC-010)*
- **V-I2** Every `divergence` verdict carries a Complexity Tracking reference.
  Exactly one is expected: the reserved-spend hatch. *(FR-027, research §5)*
- **V-I3** The inventory covers, at minimum: the mono-vs-sans role split per text
  node; the 100 re-pointed border/text sites of §2; status-color-on-non-status
  judgments; shadow-for-elevation-only; empty-state wording; recovery-path
  ranking and consequence hints; ordinal zero-padding; identifier ellipsis.

---

## 7. Relationships

```
Design token ──1:N──> consumed by ──> Console surface
     │                                      │
     │ (7 status tokens)                    │ scanned by
     ▼                                      ▼
   Status ──1:7 representations──>   DesignContract.scan/1 ──> [Violation]
     │                                      │
     │ transported as data-status           │ rules it cannot decide
     ▼                                      ▼
 stylesheet [data-status] rules      Compliance inventory row
```

- A token has one definition and many consumers; no consumer holds a copy.
- A status has one token and seven representations; every representation reads
  the token through a `data-status` rule.
- A console surface is scanned for the mechanical rules and inventoried for the
  judgment rules. The two sets partition the contract with no overlap and no gap
  (V-I1).
