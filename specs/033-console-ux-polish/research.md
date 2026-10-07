# Research: Operator Console UX Polish (033)

Each entry records a decision, why it was taken, and what was rejected. File
references point at the code as it stands on `main` (6f8aa5a).

## R1. Where `__given__=%{...}` on Run Detail comes from

**Finding.** Nothing in `lib/` writes `__given__`. The three `attr/3`
declarations at `lib/autonomous/web/live/run_detail_live.ex:408-410` sit above
`defp settings_chips/1` (:417), not above `run_header/1` (:429), which they
were written for. Phoenix.Component attaches declared attrs to the *next*
function definition, so LiveView treats `settings_chips/1` as a function
component and returns `Map.put(merged, :__given__, original)` from it
(`deps/phoenix_live_view/lib/phoenix_component/declarative.ex:665-678`). The
`:for` at :449 then iterates that map and prints the extra key through
`inspect/1`.

**Decision.** Move the `attr` block onto `run_header/1`. Also replace the
chip loop with a pure `RunSettingsView.rows/1` (data-model.md) that takes an
explicit allowlist of `RunContext.to_map/1` keys, so a bookkeeping key can
never reach the page again even if another component wrapper leaks one.

**Rationale.** It fixes the cause, not the symptom. The allowlist is the
second layer that SC-001 asks for: "zero bookkeeping keys" becomes a property
of a pure function that a unit test can check.

**Alternatives rejected.** Filtering `__given__` in the template treats the
symptom and leaves the component-wrapping in place. A deny-list of keys
fails open on the next leak.

## R2. `containment_profile` shown three times

**Finding.** When permissive, it renders in the SETTINGS chips (:449), again
inside the `__given__` dump, and in the dedicated CONTAINMENT block (:454-464).

**Decision.** `RunSettingsView.rows/1` always drops `containment_profile`. The
dedicated CONTAINMENT block, with its pointer to `docs/enforcement.md`, is the
single place it appears, and only when permissive. A strict run still shows no
containment line, so the 030 contract (`specs/030-permissive-containment/contracts/operator-surfaces.md`, strict byte-identical) holds.

## R3. Setting values without quoting artefacts

**Decision.** A pure `RunSettingsView.format_value/1`:

| Value | Rendered |
|---|---|
| binary | as-is (`main`, not `"main"`) |
| atom | `:atom` for real atoms (`:high`, `:proceed`), the system vocabulary (§I.3) |
| `nil` | `—` (em dash; the existing console placeholder) |
| integer / float | `Integer.to_string/1`; money keys via `CoreComponents.format_money/1` |
| boolean | `true` / `false` |
| list | comma-joined `format_value/1` of each element |
| map | `k=v` pairs, space-joined, keys sorted, `__`-prefixed keys dropped |

It never calls `inspect/1`. The same helper replaces `inspect/1` in the
amendment chips (:470-471) and in Escalations' identical `{k}=<span>{inspect(v)}</span>`
pattern (`escalations_live.ex:647,664,678`). Error formatters and flash
messages keep `inspect/1`: they echo a call, which is §V's toast rule.

## R4. Transcript markup rendering without a new dependency

**Finding.** No markdown library is in `mix.lock`. Transcripts render verbatim
in `<pre class="transcript-body">` (`transcripts_live.ex:217`; the Run Detail
inline panel at `run_detail_live.ex:250-264` does the same).

**Decision.** A small, in-tree, pure renderer `Autonomous.Web.TranscriptMarkup`
(`render/1 :: Phoenix.HTML.safe()`). It supports exactly what FR-004 names:
ATX headings, `*em*`/`_em_`, `**strong**`, inline code, fenced code blocks,
and ordered/unordered lists nested by indentation. It works line-by-line,
block first, then inline. **Every text run is passed through
`Phoenix.HTML.html_escape/1` before any tag is emitted**, so embedded HTML is
inert by construction (FR-005). An unclosed fence runs to end of document; an
unmatched inline delimiter is emitted as literal text. Content is never
dropped (edge case "malformed markup").

**Rationale.** Constitution Technology Stack: a runtime dependency must be
justified against the stack, and backend work "MUST prefer OTP primitives
already in the tree". The needed subset is small and the safety property
(escape-first) is easier to prove in ~200 lines we own than to configure in a
general renderer.

**Alternatives rejected.**
- *Earmark*: passes raw HTML blocks through by default. Safety then depends
  on option discipline at every call site, and it adds a Hex dependency.
- *MDEx*: Rust NIF. Adds a native toolchain surface for a display nicety.
- *Client-side JS renderer*: forbidden without clearing the no-build-step bar,
  and would move rendering out of tested Elixir.

**Verification.** Property test (StreamData, already a dev/test dep): for any
input string, the rendered output contains no `<` that was not emitted by the
renderer's own tag set, and stripping tags from the output yields the
HTML-escaped input text with no characters lost.

## R5. Transcript measure and family

**Decision.** `.transcript-body` keeps `--font-mono` at `--fs-transcript`
(12.5px, line-height 1.7) and gains `max-width: 96ch` with
`white-space: normal` on prose blocks and `pre` on fenced blocks (horizontal
scroll inside the fence, never on the page). A new token `--measure-transcript: 96ch` holds the value (FR-035).

**Guard impact.** `:root` names are a closed list (`design_contract.ex:115-125`).
Every new token in this feature is added to that list in the same change:
`--measure-transcript`, `--rail-compact`, `--card-min` (layout family, new
`@layout_tokens`) and `--border-input` (derived, `var(--text-faint)`, no new
hex). No new color value is introduced; only three existing values change (R8).

## R6. Transcripts run selector

**Finding.** The run comes from `params["run_id"] || current_run_id() || latest_run_id()`
(`transcripts_live.ex:24`); no selector exists.

**Decision.** A `<select class="console-input">` fed by
`Autonomous.run_history(limit: 20)`, labelled `run_id`, defaulting to today's
resolution order. Changing it `push_patch`es `?run_id=…`, so the URL stays the
receipt and the existing `params` path is reused.

## R7. Status chips and run state

**Finding.** Runs uses `badge badge-neutral|badge-warn` for `run.state`
(`runs_live.ex:170`); Run Detail prints `{@run.state} · {@run.outcome}` as
plain text (:439). Neither travels status as `data-status`.

**Decision.** A pure `RunStateView.status/1` maps the four run states the
store writes (`:in_flight`, `:completed`, `:parked`, `:superseded`) and the
run outcomes to the existing status names (`CoreComponents.statuses/0`):
`:in_flight` → `running`, `:completed` → `done`, `:parked` → `escalated`,
`:superseded` → `blocked`; outcome `:interrupted` → `blocked`,
`:ended_by_operator` → `pending`, a feature status atom → its own
`status_class/1`, anything else → `pending`. Both views render
`<span class="status-chip" data-status={…}>{inspect(state)}</span>`. The chip
text is the real atom (`:in_flight`), never a friendly label (FR-036).

The mapping table is recorded in `contracts/console-surfaces.md` and checked by
a unit test so a new run state cannot silently fall back.

## R8. Contrast (FR-008, FR-038, SC-011) — token amendment

**Finding.** Measured WCAG 2.x contrast of shipped tokens against the four
surfaces (`--bg` … `--raised`):

| Token | Value | Worst case | Needs |
|---|---|---|---|
| `--text-faint` | `#5a6274` | 2.85 (raised) | 4.5 |
| `--pending` | `#64748b` | 3.47 (chip fill on card) | 4.5 |
| `--blocked` | `#475569` | 2.25 (chip fill on card) | 4.5 |
| `--accent` as text | `#7c5cff` | 4.01 (raised) | 4.5 |
| chip `X40` borders | — | 1.19–2.06 | 3 (non-text) |
| `--border`/`--border-strong` | — | 1.20–1.50 | 3 (non-text) |

Every other text token and every other status color passes 4.5:1 on every
surface, including inside a `1a` chip fill. The spec's assumption that AA was
reachable "without palette redesign" is false for three tokens.

**Decision (operator, 2026-10-07).** Amend text-bearing tokens; scope the
non-text rule the way WCAG 1.4.11 does.

- `--text-faint: #7a8296` (4.53 on `--raised`, 5.05 on `--bg`). Still below
  `--text-muted` (6.32 on `--bg`), so the four steps stay ordered.
- `--pending: #94a3b8` (5.76 in a `1a` chip fill on `--raised`). Slate, not a hue.
- `--blocked: #828ea3` (4.58 in a chip fill on `--raised`, the worst case). Slate, darker than `--pending`, so the two stay distinct. A first candidate, `#7a879c`, passed as solid text but failed inside a chip fill (4.22).
- `--accent` is not used as text. Where a surface uses it as text today it
  moves to `--accent-light` (7.14 on bg). `--accent` stays for fills, the
  active nav ring and focus.
- Non-text 3:1 applies where a border or fill is the **only** carrier of state
  or affordance: focus ring (`--accent` 4.47 on bg, passes), gauge fills,
  switch/checkbox state, and an input's boundary. Inputs get a derived
  `--border-input: var(--text-faint)` token, 5.05:1 against `--bg` (see R9). Chip borders and
  future phase pips are exempt: the chip text and the pip `title` plus the
  phase label (FR-020) carry the state.

FR-038 is reworded in `spec.md` to match. Changing token values is an
amendment of `docs/design-constitution.md` §II (FR-037): the tables and the
`:root` snippet are updated in the same change, with a rationale line, and the
constitution's Operator Surface Design section needs no edit because it holds
no values. The guard pins every contract hex (`@contract_colors`,
`design_contract.ex:~80-108`), so the three values change there too. The
frozen 011 artifact is historical and is not touched. The guard also gains a
contrast check that reads the token block and asserts the ratios above, so a
later value change fails loud.

**Alternatives rejected.** Literal FR-038 (solid chip borders, raised
`--border-strong`): busier surface and a larger amendment of the chip spec for
no information gain. Text-only exemption: leaves eyebrows and meta below AA.

## R9. Themed form controls (FR-009)

**Finding.** Runs filters use `class="resume-select"` (`console.css:1442-1452`,
shared with `.resume-textarea`). Trigger's selects and number inputs
(`trigger_live.ex:439,529,542,555,607,619,645`) and Config's text inputs
(`config_live.ex:205-212`) have no class. CSS has no rule for bare `select`,
`input[type=number]` or `input[type=range]`; only scoped ones
(`.dag-wave-picker select` :1927, `.config-pr-fields input` :2276).

**Decision.** Rename the shared style to `.console-input` and migrate every
`resume-select` use in the same change (no alias left behind). Apply it to
every `select` and text-like `input` in the console; its border is
`--border-input` (R8). Delete the scoped one-off rules it replaces. Add
`color-scheme: dark` on `:root` so native popups, number spinners and the
range track render dark. No custom chevron image: a background image on a
control would be a background graphic the prohibitions list does not allow.
The native arrow under `color-scheme: dark` suffices. The design-contract guard gains a rule:
every `<select>` and `<input type="number|text|search">` in a `.heex`/`~H`
template carries `console-input` (SC-006).

## R10. In-flight detection and the two-step start (FR-010/011)

**Finding.** Trigger has no live run awareness. Both start actions go through
`Autonomous.run/1`, which drains and supersedes any prior in-flight run
(`lib/autonomous.ex:104,198-209`; `run_spec/2` delegates to `run/1`).

**Decision.** `TriggerLive` subscribes to `ConsoleProjection.topic()` and, on
mount and on every `{:console, :reconciled, _}`, recomputes `active_run_id`:
`Autonomous.current_run_id()` when the Coordinator is alive or
`Autonomous.workers/0` is non-empty, else `nil`. A pure
`StartConfirm.next(state, event)` state machine (data-model.md) drives the
button: `:idle → :armed` on first click when `active_run_id` is set;
`:armed → :confirmed` (start dispatched) on second click; `:armed → :idle` on
cancel, on `active_run_id` becoming `nil`, or on tab switch. With no active
run the first click dispatches directly (FR-011). Navigation away discards LV
state, which returns the button to idle by construction.

The armed state is per action (`:backlog` / `:single_spec`), and the start
handler re-checks `active_run_id` server-side, so a stale client cannot skip
the arm step.

**Alternatives rejected.** `data-confirm` (browser `confirm()` modal) —
the clarification chose inline two-step, no modal. A JS hook — LiveView
expresses this server-side.

## R11. Narrow-width layout (FR-014–016)

**Finding.** The only width queries are `max-width: 1120px` (`console.css:746`,
`:1851`). `.console-sidebar` is `flex: 0 0 236px` with no responsive rule;
`.topbar-gauge` is `flex: 0 0 280px`; the sidebar path uses
`word-break: break-all` (:547).

**Decision.** Add one narrow breakpoint, `@media (max-width: 760px)`. CSS
custom properties cannot appear in a media query, so the guard gains a
breakpoint allowlist `~w(1120px 760px)` and fails any other `@media` width.

Below it:
- `.console-sidebar` becomes `flex: 0 0 var(--rail-compact)` with
  `--rail-compact: 52px` (added to `@layout_named_values` as well, since the
  spacing rule checks raw px on layout lines). Nav items show a short mono label (`MC`, `PC`,
  `TR`, `ES`, `RU`, `TX`, `CF`) plus the badge; the full label sits in
  `aria-label` and `title` (FR-015). The rail stays persistent and single
  level (§VII.1).
- The topbar wraps into two rows: state chip + subject, then gauge (full
  width). The clock hides; the breaker chip stays.
- Feature tables switch to a stacked row: id + status chip on line one,
  `phase · n/7` and spend on line two (CSS grid on the `<tr>` with
  `display: grid`; non-essential columns `display: none`). No horizontal page
  scroll (FR-016).
- Drawer width becomes `min(460px, 100vw)` (edge case).

The DAG keeps its own horizontal scroll inside its panel (not the page).

## R12. Budget gauge (FR-017)

**Finding.** `cost_gauge/1` (`core_components.ex:215-266`) already draws two
bars (reserved width = committed+reserved, fill width = committed, the only
two allowlisted inline styles) and sets `data-band` safe/warning/tripped. The
label reads `$X / $Y (armed|tripped)` with X = committed + reserved, so the
figure merges what the bars separate, and the breaker word repeats the topbar
breaker chip (`app.html.heex:77-79`).

**Decision.** Keep the markup, bars and band. The label becomes
`$committed + $reserved / $budget` in mono beside the bar, never on it, and
drops the breaker word. Committed over 100% clamps the bar at 100% width; the
label shows the real figure. The band colors stay as shipped (`console.css:361-407`).

## R13. Topbar clock (FR-018)

**Finding.** `layouts.ex:74`: `DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()`
prints microseconds.

**Decision.** `Time.truncate(:second)` before `Time.to_string/1`, plus a `UTC`
suffix in the template.

## R14. Mission Control status strip and phase label (FR-019/020)

**Decision.** The eight KPI tiles become one `.status-strip` row of
`dot · :status · count` cells; a zero count gets `data-zero` and renders in
`--text-muted` (still ≥4.5:1, de-emphasized, not hidden). `phase_strip/1` (`core_components.ex:156-176`) already prints each phase name
inside its cell, but the cells are too narrow to read at table width, and
015's golden test pins its render byte-for-byte (`phase_strip_test.exs`). So
`phase_strip/1` is not touched. A new sibling component
`phase_position/1` renders a mono `{phase} · {n}/{total}` label, computed by a
pure `CoreComponents.phase_position/1` from the same `phases` map and
`Pipeline.phases/0`, so pips and label cannot disagree. Every caller that
renders a feature's progress (Mission Control table, Pipeline Chain card,
feature drawer) renders both. Per-pip `title` stays.

## R15. Telemetry feed (FR-021)

**Finding.** Rows are `li.feed-entry.feed-<severity>` with `feed-time` and one
`feed-text` span (`mission_control_live.ex:303-310`); the feature id is only in
`data-feature-id`.

**Decision.** Reuse §V event-feed: `time · status-dot · mono id · sans predicate`,
newest first. The dot's `data-status` comes from the entry's feature status
via `status_class/1`, not from severity. Predicate text keeps real
identifiers (`:clarify stopped :ok`).

## R16. Configuration (FR-022–026)

**Findings.** Budget is `<input type="range">` with an inline `oninput`
(`config_live.ex:178-187`); no Reset; Apply only reports budget/pr fields;
`LiveConfig.apply/1` is all-or-nothing and forward-only
(`lib/autonomous/live_config.ex:38-120`).

**Decisions.**
- `phx-change="edit"` keeps a `pending` map; a pure `ConfigDiff.diff(applied, edited)`
  drives `data-dirty` and a sticky action bar (`position: sticky; bottom: 0`)
  with Apply, Reset and `n unsaved` (FR-022).
- Budget gets `<input type="number" step="0.01" min="0" class="console-input">`
  as the authority; the range slider stays, both bound to the same assign, and
  the inline `oninput` script is removed (no inline JS; LiveView updates it).
  Parsing uses `Decimal`-free cent parsing: string → `Float.parse/1`, then
  `Float.round(_, 2)`; values with more than 2 decimals are refused as
  `:invalid` rather than rounded silently (Principle II).
- The toast echoes `LiveConfig.apply(%{...})` with every changed key, models
  included, and, when a run is in flight, the mono line
  `applies forward-only to <run_id> · not saved as default` (FR-024).
- Served repository and instance node move into a `<.record_block>` (FR-025).
- Section titles: visible `<legend>` replaced by the `.config-toggle-title`
  pattern everywhere, and `fieldset { padding-top }` fixed so no title
  overlaps a border (FR-026).
- Errors for `pr_base`/`pr_remote` get the same `.form_refusal` as budget.

## R17. Clean load (FR-034)

**Findings.** No `/favicon.ico` route or link. Two `rel=preload` font links in
`root.html.heex`. The four `ibm-plex-sans-*.woff2` files are byte-identical
(md5 `b2c9031d…`), which is out of scope here but recorded.

**Decisions.**
- `<link rel="icon" href="data:,">` in the root layout: no request, no 404, no
  new static file, no color literal.
- Drop both preload links. The fonts are same-origin, `font-display: swap`, and
  requested as soon as the stylesheet parses; the preloads only produced the
  "preloaded but not used" warning.

## R18. Secondary views (FR-027–033)

- **Pipeline Chain**: today `.dag-chain` is a vertical flex column capped at
  `max-width: 460px` (`console.css:998`) with a `::before` connector. It
  becomes `display: grid; grid-template-columns: repeat(auto-fill, minmax(var(--card-min), 1fr))`
  with `--card-min: 280px`, reading left-to-right in `Release.order/1`. The
  vertical connector is dropped; each card's existing "stacks on {base}" line
  carries the relation. The positional ordinal (`pad_ordinal(link.position)`,
  `pipeline_dag_live.ex:452`) is dropped; the feature id stays. The legend
  (:390-404) renders only statuses present in the chain. The wave picker
  (:301-316) gets a visible `<label for>` naming `slug`.
- **Labels (FR-028)**: nav label "Pipeline DAG" (`layouts.ex:21-29`) becomes
  "Pipeline Chain", matching the page title.
  Casing rule: status chips show the atom (`:done`); prose labels use
  sentence case. Recorded in `contracts/console-surfaces.md`.
- **Sidebar path (FR-029)**: `Path.basename(repo)` in mono with ellipsis,
  `title` = full path, plus a copy button using LiveView's `JS.dispatch("phx:copy")`
  and a five-line listener in `priv/static/assets/app.js` calling
  `navigator.clipboard.writeText`. No build step.
- **Empty state (FR-030)**: title at `--fs-card-title` 600, body at
  `--fs-body` `--text-muted`.
- **Runs feature column (FR-031)**: pure `RunStateView.status_counts/1` →
  `done 3 · running 1 · pending 2`, each count a status-colored dot + mono.
- **Trigger summary (FR-032)**: "DAG validated" → `yes`/`no` stays as a value,
  label a statement; `truncate_path/1` replaced by a path relative to the
  served repo root (full path in `title`), ellipsized at the end via CSS.
- **Run Detail phase rows (FR-033)**: the standard density is the shipped
  data-table cell, `padding: var(--sp-14) var(--sp-18)` (`console.css:820`).
  §IV writes "13px vertical", but 13 is off its own 2px grid and the guard's
  spacing rule rejects it; the shipped 14px is the standard, and the spec's
  "13px" wording is corrected to "standard data-table density". The
  transcript toggle becomes a `.btn-link` (no border, no padding) so it does
  not inflate the row.

## R19. Design-contract guard extensions (FR-035, SC-009)

The guard (`test/support/design_contract.ex`) declares its rule set closed per
`specs/020-reconcile-console-design/contracts/design-guard.md` §5. That 020
contract is a historical record and is not rewritten. This feature's
`contracts/design-guard-extensions.md` records the additions, and the guard's
moduledoc cites both. Nothing is relaxed. Existing rules change only by
allowlist growth that this plan names:

- `@contract_colors`: three values change (R8).
- `:root` names: `@layout_tokens ~w(--measure-transcript --rail-compact --card-min)`,
  plus `--border-input` in `@derived_tokens`.
- `@layout_named_values`: add `52px` and `280px` stays.

New rules, each with a fires / does-not-fire test pair in
`design_contract_test.exs`:

1. **G-contrast**: parse `:root`, assert the R8 ratios for every text token on
   every surface and every status color in a `1a` chip fill.
2. **G-input**: every `<select>` and text-like `<input>` in a scanned surface
   carries `console-input`.
3. **G-breakpoint**: every `@media (max-width|min-width: …)` uses a width in
   `~w(1120px 760px)`.
4. **G-inspect**: no `inspect(` inside a HEEx interpolation `{…}` in a scanned
   surface. Flash and error-message builders run in Elixir function bodies,
   not inside `~H`, so they are not matched.
