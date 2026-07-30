# Quickstart: validating the console reconciliation

**Feature**: `020-reconcile-console-design`

Runnable scenarios that prove the feature end-to-end. Every command runs through
mise (`mise exec --`) per the constitution's Quality & Test Discipline; the bare
PATH Elixir is stale.

Details live in the artifacts rather than here:
[`contracts/token-set.md`](contracts/token-set.md) ·
[`contracts/status-transport.md`](contracts/status-transport.md) ·
[`contracts/design-guard.md`](contracts/design-guard.md) ·
[`data-model.md`](data-model.md).

---

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

The console runs on the app's Phoenix endpoint; no Node, no npm, no build step
(and none may be added — SC-008).

---

## Scenario 1 — The guard passes on a clean tree, and names divergence when it returns

Covers **US4**, FR-023, FR-024, SC-007.

```bash
# 1a. Clean tree: the default suite passes, guard included.
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs
```

**Expected**: green. The clean-tree assertion is `scan/1 == []`; on failure the
message is one line per violation, `path:line rule — excerpt`.

```bash
# 1b. Full default suite stays hermetic — no browser, no network, no store setup
#     for the guard, and no --include integration.
mise exec -- mix test
```

**Expected**: green, and the run time for `design_contract_test.exs` is dominated
by file reads, not by a Coordinator or a socket.

```bash
# 1c. Inject each of the four guarded divergence classes and confirm 4/4 fail.
#     These are unit cases inside the test file (crafted source maps, no tree
#     mutation) — run them directly:
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs --only injection
```

**Expected**: four passing tests, each asserting the injected source yields the
named rule *and* the correct line — a raw color literal, a duplicated status
value, a fifth keyframe, and a color-bearing inline style.

```bash
# 1d. Prove it against the real tree once, by hand.
printf '\n.qs-probe { color: #34d399; }\n' >> priv/static/assets/console.css
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs
# Expected: FAILS, naming priv/static/assets/console.css and the appended line,
#           with both :color_literal and :duplicate_status_value.
rtk git checkout -- priv/static/assets/console.css
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs
# Expected: green again.
```

```bash
# 1e. A new console surface cannot escape the guard by simply existing.
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs --only coverage
```

**Expected**: green; the test compares `DesignContract.surfaces/0` against the
on-disk console surface set and fails if either side has an entry the other lacks.

---

## Scenario 2 — One authoritative token set

Covers **US1**, FR-001–FR-005, SC-001, SC-002, SC-003.

```bash
# 2a. Every contract token present, under its contract name, with its value.
#     Asserted by the guard; confirm by eye against the contract's §II block.
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs --only tokens
```

```bash
# 2b. Zero color literals outside :root (baseline was 99 outside + 4 rgba()).
awk '/^:root \{/{r=1} r&&/^\}/{r=0;next} !r' priv/static/assets/console.css \
  | grep -nE '#[0-9a-fA-F]{3,8}|rgba?\(|hsla?\('
# Expected: no output.
```

```bash
# 2c. Zero color literals and zero color-bearing inline styles in server code
#     (baselines: 14 hex literals, 6 inline styles).
rtk grep -rn '#[0-9a-fA-F]\{6\}' lib/speckit_orchestrator/web/
rtk grep -rn 'style=' lib/speckit_orchestrator/web/
# Expected: nothing for the first; exactly two `width:` lines in
#           core_components.ex's cost_gauge/1 for the second (FR-004b).
```

```bash
# 2d. No retired token survives (baseline: 42 + 4 + 3 + 1 = 50 sites).
rtk grep -rn 'var(--muted)\|var(--accent-2)\|var(--link)\|var(--link-hover)' \
  priv/static/assets/console.css
# Expected: no output.
```

```bash
# 2e. One definition per status, reached by every representation.
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs --only status
```

**Manual check (2f)** — the propagation proof of acceptance scenario 3: change
`--escalated` in the `:root` block to `#ff00ff`, reload, and confirm the
escalations dot, the chip, the phase pip, the DAG node border, the timeline node,
the gauge warning band, and the legend swatch **all** turn magenta and none keeps
`#fbbf24`. Revert.

---

## Scenario 3 — Surfaces obey the color, type and component specs

Covers **US2**, FR-006–FR-014, SC-005, SC-009.

```bash
mise exec -- iex -S mix
```

```elixir
# Start the endpoint and open the console.
# Every view: /  /dag  /trigger  /escalations  /runs  /transcripts  /config
```

Walk each of the eight views and confirm, against
[`contracts/token-set.md`](contracts/token-set.md) §6 and the contract's §II–§V:

| Check | Expect |
|---|---|
| Chips | fill = status at 10% (`1a`), border = status at 25% (`40`), radius `--r-chip`, 10px mono 600 — **not** an opaque border, **not** a `999px` pill |
| Text roles | values/body `--text-secondary`, descriptions `--text-muted`, eyebrows 10px mono uppercase `--text-faint` — no `#8b93a7`, no `--muted` |
| Borders | row dividers `--hairline`, region dividers `--border-subtle`, card borders `--border`, interactive `--border-strong` — each one step *darker* than today |
| Mono/sans | IDs, slugs, phases, statuses, paths, branches, counts, money, durations, timestamps all mono; prose all sans; no element mixing |
| Identifiers | ellipsize on one line, never wrap |
| Ordinals | zero-padded (`01`, `007`) |
| Phase pips | one equal-width fixed-length track, identical in mission control, DAG node and drawer; every pip's `title` names phase **and** state |
| Persisted artifacts | checkpoint, transcript path, PR and run record all render as record blocks — accent eyebrow over mono key/value pairs — not bespoke boxes |
| Toasts | `--raised` on a 1px accent border, echoing the call and its arguments; **no** status-colored border |
| Prohibitions | no `#fff`/`#000`, no background gradient (except the recorded reserved hatch), no second accent hue, no centered body text, no status color on a non-status element, no nav pictograph, no shadow on a resting surface, nothing below 10px |
| Information parity (SC-009) | every view shows the same data and offers the same routes as before |

```bash
# 3a. Confirm the prohibited pictographs are gone and the contract's stay.
rtk grep -rn 'nav_glyph\|@nav_glyphs\|&#9654;\|&#8635;\|&#8801;' lib/speckit_orchestrator/web/
# Expected: no output.
rtk grep -rn '✓\|●\|✕' lib/speckit_orchestrator/web/components/feature_drawer.ex
# Expected: the §V timeline marks only.
```

---

## Scenario 4 — Motion and the interaction law

Covers **US3**, FR-015–FR-022, SC-004, SC-006.

```bash
# 4a. Exactly four keyframes, nothing else, all reduced-motion-stoppable.
rtk grep -n '@keyframes' priv/static/assets/console.css
# Expected: scPulse, scBlink, scSlide, scFade — exactly these four.
rtk grep -n 'prefers-reduced-motion' priv/static/assets/console.css
# Expected: one block naming every animated selector.
```

**Live-vs-resting (4b, SC-004).** Start a run with one feature working and several
resting:

```elixir
SpeckitOrchestrator.run(repo: "../ledgerlite")
```

- **Motion enabled**: only the active feature's dot and current pip pulse. Every
  resting, pending, blocked, and terminal dot is still and carries **no glow**.
- **Motion reduced** (OS setting, or DevTools → Rendering → emulate
  `prefers-reduced-motion: reduce`): nothing animates, and the active feature is
  still identifiable at a glance from the `--glow-accent` ring on its DAG node
  and the current pip in the status color against `--border` future pips. The
  distinction must not rest on reading status text.

**Live stream (4c)**: open `/transcripts` for a phase whose attempt has not
finished — the live indicator blinks. Open a finished attempt — it does not.

**Recovery ranking (4d, FR-017, FR-018, SC-006)**: on `/escalations` for a
diverted feature, confirm `resume/2` is the gradient primary and `resolve/1`
(full restart) is a bordered secondary **in the same row**, each with a mono
consequence hint, and that `:from` and `:prompt` appear under their real option
names defaulting to what the system would choose unaided.

**Parked run (4e, FR-017)**: with a parked run, confirm `continue_run/1` and
`end_run/1` are ranked and consequence-labelled, never one ambiguous button, and
that the banner is no longer the `failed`-red `.field-error` treatment.

**Gauge (4f, FR-016)**: confirm committed reads as a solid fill and reserved as
the hatched band behind it, and that the band color moves `safe → warning` above
80% and `tripped` on `Ledger.tripped?`.

**Empty state (4g, FR-022)**: with no open escalations, `/escalations` states the
healthy condition and why, left-aligned, with no call to action and no icon — the
28px `done`-green check is gone.

**Inspectability (4h, FR-021)**: click a backlog row, a DAG node and a drawer card
for the same feature — each opens the same detail surface.

---

## Scenario 5 — The verification split is complete

Covers FR-026, FR-027, SC-010.

```bash
rtk read specs/020-reconcile-console-design/compliance-inventory.md
```

**Expected**: a row per surface × element × rule × verdict, covering every
judgment rule in [`contracts/design-guard.md`](contracts/design-guard.md) §5's
inventory column, with:

- zero rules unassigned to either means,
- zero claims resting on assertion alone,
- exactly one `divergence` verdict — the reserved-spend hatch — carrying its
  Complexity Tracking reference in `plan.md`.

```bash
# 5a. No new dependency, no build step (SC-008).
rtk git diff main -- mix.exs mix.lock
# Expected: no output.
```

```bash
# 5b. The superseded feature-local contract is untouched (FR-005).
rtk git diff main -- specs/011-control-plane-ui-redesign/contracts/design-system.md
# Expected: no output.
```

---

## Full-suite gate

```bash
mise exec -- mix test
mise exec -- mix test --cover        # pure core stays >90%
mise exec -- mix format --check-formatted
```

All three must pass before the feature is complete. `warnings_as_errors` means a
compiler warning is a failure, not a note.
