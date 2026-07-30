# Contract: the compliance guard

**Feature**: `020-reconcile-console-design` | **Requirements**: FR-023, FR-024, FR-026, FR-027

The mechanical half of the verification split. A pure scanner over console source
that fails the **default** test suite when divergence returns, naming the file and
line. The judgment half lives in `compliance-inventory.md`.

---

## 1. Placement and shape

**Module**: `SpeckitOrchestrator.Web.DesignContract`
**File**: `test/support/design_contract.ex`
**Driver**: `test/speckit_orchestrator/web/design_contract_test.exs`

`test/support` is on `elixirc_paths` for `:test` only (`mix.exs:18`), so the lint
ships **no runtime code** and adds **no dependency** *(SC-008)*.

```elixir
defmodule SpeckitOrchestrator.Web.DesignContract do
  defmodule Violation do
    @enforce_keys [:rule, :path, :line, :excerpt]
    defstruct [:rule, :path, :line, :excerpt]
    @type t :: %__MODULE__{rule: atom(), path: String.t(), line: pos_integer(), excerpt: String.t()}
  end

  @doc "Console surfaces the guard governs, repo-relative."
  @spec surfaces() :: [String.t()]

  @doc "Read `surfaces/0` from disk into the `scan/1` input shape."
  @spec load(Path.t()) :: %{String.t() => String.t()}

  @doc "Pure. Every violation in the given sources, ordered by path then line."
  @spec scan(%{String.t() => String.t()}) :: [Violation.t()]

  @doc "Human-readable failure message: one line per violation, `path:line rule — excerpt`."
  @spec format(the_violations :: [Violation.t()]) :: String.t()
end
```

**Contract**

- **G-1** `scan/1` is pure: no file I/O, no network, no shell out, no process.
  All I/O is confined to `load/1`, which the real-tree test calls once.
  *(FR-024, SC-008)*
- **G-2** Every `Violation` carries `path` and `line`. A rule that cannot localise
  its finding is not admitted. *(FR-023)*
- **G-3** `scan/1` on the reconciled tree returns `[]`. *(SC-007)*
- **G-4** The rule set below is **closed**. Adding a rule is a spec change; a rule
  MUST NOT be silenced by adding an exception in place — the exception goes in
  the allowlist tables here, with a reason.
- **G-5** The guard does **not** assert appearance. It asserts that no value is
  duplicated, no prohibition is mechanically present, and no motion lacks a
  referent. What a surface *looks* like is the inventory's job.

---

## 2. Input domain

`surfaces/0` is the fixed list from `data-model.md` §4:

```
priv/static/assets/console.css
priv/static/assets/app.js
lib/speckit_orchestrator/web/components/core_components.ex
lib/speckit_orchestrator/web/components/feature_drawer.ex
lib/speckit_orchestrator/web/components/layouts.ex
lib/speckit_orchestrator/web/components/layouts/app.html.heex
lib/speckit_orchestrator/web/components/layouts/root.html.heex
lib/speckit_orchestrator/web/live/*.ex          (8 views, enumerated not globbed)
```

- **G-6** The list is **enumerated, not globbed**. A new console surface that is
  not added to `surfaces/0` fails a dedicated coverage test that compares
  `surfaces/0` against the on-disk set — so a new view cannot escape the guard by
  simply existing. Rationale: two prior features in this repo shipped glob defects
  in artifact gates; an explicit list plus a coverage check fails loud both ways.
- `app.js` is in the domain despite being 7 clean lines, so it cannot become a
  hiding place for a literal.

---

## 3. Rule set

### 3.1 Token integrity — `console.css` only

| Rule | Fires when |
|---|---|
| `:missing_token` | a §II token is absent from the `:root` block |
| `:token_value_mismatch` | a §II token's value differs from the contract's, **or** equals another §II token's value |
| `:retired_token` | `--muted`, `--accent-2`, `--link`, `--link-hover` declared or referenced |
| `:undeclared_token` | `var(--x)` where `--x` is not declared in `:root` |
| `:unexpected_token` | a `:root` declaration outside the token families of `token-set.md` |

The 24 §II names and values are embedded as module attributes, transcribed from
`docs/design-constitution.md` §II. **G-7**: a dedicated test asserts the
transcription matches the doc's fenced CSS block by parsing the doc at test time —
so the guard cannot drift from the contract it enforces.

### 3.2 Literals

| Rule | Fires when |
|---|---|
| `:color_literal` | `#hex` (3/4/6/8 digit), `rgb(`, `rgba(`, `hsl(`, `hsla(`, or a CSS named color outside the `:root` span in `console.css`, or **anywhere** in a `lib/**/web/**` or `app.js` source |
| `:offscale_radius` | `border-radius:` with anything but a `var(--r-*)` or `--r-*` declaration |
| `:offscale_font_size` | `font-size:` with anything but a `var(--fs-*)` or `--fs-*` declaration |
| `:offgrid_spacing` | `padding`/`margin`/`gap`/`top`/`right`/`bottom`/`left` with a `px` literal not on the 2px grid and not in the layout allowlist |
| `:illegal_alpha_suffix` | a `color-mix` percentage outside `status-transport.md` §3's table, or a hex alpha suffix outside `0d·1a·22·40·55·66·88` |

**Layout allowlist** (`:offgrid_spacing`, `:offscale_*` exempt — dimensions the
contract does not fix, FR-004): `width`, `height`, `min-*`, `max-*`, `flex-basis`,
`grid-template-*`, `letter-spacing`, `line-height`, `border-width`, `z-index`,
and the named layout constants `236px` (sidebar), `460px` (drawer), `280px`
(topbar gauge), `22px` (page padding — also `--sp-22`).

### 3.3 Status duplication

| Rule | Fires when |
|---|---|
| `:duplicate_status_value` | any of the 7 status hex values appears outside the `:root` block, in any source, in any case, with or without an alpha suffix |
| `:unknown_status_selector` | a `[data-status="x"]` or `.status-x` selector where `x` is not one of the seven |
| `:status_color_in_elixir` | a `lib/**/web/**` source contains a status name adjacent to a color property, or returns a value matching a status hex |

`:duplicate_status_value` is the rule that catches the spec's "second copy —
including one whose values match".

### 3.4 Inline styles

| Rule | Fires when |
|---|---|
| `:inline_style_color` | a `style=` attribute whose value mentions `color`, `background`, `border`, `fill`, `stroke`, `box-shadow`, `gradient`, `font`, `radius`, `padding`, `margin`, or interpolates anything not on the allowlist |

**Allowlist** — exactly two loci, both in `core_components.ex`'s `cost_gauge/1`:

```
style={"width: #{@fill}%;"}
style={"width: #{@committed_fill}%;"}
```

Any third inline style, or either of these two gaining a second declaration,
fires. *(FR-004b)*

### 3.5 Motion

| Rule | Fires when |
|---|---|
| `:unknown_keyframe` | an `@keyframes` name outside `scPulse scBlink scSlide scFade` |
| `:missing_keyframe` | fewer than all four defined |
| `:undefined_animation` | `animation:` names a keyframe with no `@keyframes` block |
| `:animation_without_referent` | a rule carrying `animation:` whose selector contains none of `running`, `active`, `live`, `drawer`, `scrim`, `toast` |
| `:unstoppable_keyframe` | a selector carrying `animation:` that the `prefers-reduced-motion: reduce` block does not also name |

`:animation_without_referent` is a **necessary, not sufficient** check — it proves
the selector is *about* a live thing, not that the thing is live. The semantic
claim is inventoried. *(G-5)*

### 3.6 Prohibitions (§VIII, mechanically decidable subset)

| Rule | Fires when |
|---|---|
| `:pure_black_white` | `#000`, `#fff`, `#000000`, `#ffffff`, `white`, `black`, or `rgb(255,255,255)`/`rgb(0,0,0)` anywhere except inside the three contract-verbatim shadow tokens |
| `:background_gradient` | a `gradient(` outside `--gradient-primary`, `--hatch-reserved`, and their two permitted consumers |
| `:second_accent_hue` | a color literal whose hue is neither the violet accent family nor a status/neutral token — subsumed by `:color_literal` after reconciliation; kept as a named rule so the prohibition is traceable |
| `:centered_body_text` | `text-align: center` in a rule that also sets `--fs-body`, `--fs-meta`, `--fs-section`, or `--fs-transcript` |
| `:sub_floor_type` | a `--fs-*` declaration below `10px`, or a prose-role token below `11px` |
| `:pictograph` | a codepoint in U+1F300–U+1FAFF, U+2600–U+27BF, U+2B00–U+2BFF, U+FE0F, or the geometric-shapes block, outside the allowlist |
| `:shadow_on_resting` | `box-shadow` outside `--shadow-drawer`, `--shadow-toast`, `--glow-accent` and their permitted consumers (`.drawer`, `.toast`, `.dag-node[data-status="running"]`) |
| `:governing_source` | `console.css`'s first 12 lines do not cite `docs/design-constitution.md`, or cite the 011 contract as a source of truth |
| `:frozen_artifact` | `specs/011-control-plane-ui-redesign/contracts/design-system.md` differs from its committed content |

**Pictograph allowlist** — the timeline node marks prescribed by §V, and nothing
else:

| Codepoint | Glyph | Basis |
|---|---|---|
| U+2713 | `✓` | §V timeline, done |
| U+25CF | `●` | §V timeline, active |
| U+0021 | `!` | §V timeline, escalated (ASCII, not matched anyway) |
| U+2715 | `✕` | §V timeline, failed |

`escalations_live.ex:554`'s `" ✓"` task-phase completion mark uses U+2713 inside a
mono machine label and is therefore allowlisted by codepoint; its *semantic*
verdict (machine value, not decoration) is inventoried.

Retired by this rule and **not** allowlisted: the seven `layouts.ex` nav glyphs
(`◧ ⊟ ▷ ⚠ ▤ ≡ ⚙`) and the three `escalations_live.ex` button glyphs (`&#9654;`,
`&#8635;`, `&#8801;`). HTML numeric entities are decoded before matching, so an
entity cannot evade the rule.

---

## 4. Driver test obligations

`design_contract_test.exs`:

1. **Clean tree.** `DesignContract.load(".") |> DesignContract.scan()` returns
   `[]`. Failure message is `format/1`, so the operator sees `path:line rule —
   excerpt` per violation. *(FR-023, SC-007)*
2. **Coverage.** `surfaces/0` equals the on-disk console surface set. *(G-6)*
3. **Doc transcription.** The embedded §II token table matches the fenced CSS
   block parsed out of `docs/design-constitution.md`. *(G-7)*
4. **Four injections** — each a crafted `%{path => source}` map, no tree
   mutation, asserting the rule **and** the reported line *(SC-007)*:

   | Injection | Expected rule |
   |---|---|
   | `.foo { color: #34d399; }` appended to a CSS surface | `:duplicate_status_value` + `:color_literal` |
   | `defp c, do: "#7c5cff"` in a view source | `:color_literal` |
   | `@keyframes scWobble { … }` | `:unknown_keyframe` |
   | `style={"background: #{@c};"}` in a view source | `:inline_style_color` |

5. **Every other rule** gets its own positive and negative case. Rules are the
   pure core of this feature; the >90% coverage bar applies.
6. **Hermeticity.** The test declares no `@tag :integration`, starts no
   Coordinator, touches no store, and opens no socket. *(FR-024)*

---

## 5. Verification split (FR-026, FR-027, SC-010)

Every contract rule this feature claims is assigned to **exactly one** means.

**Guard** (mechanically decidable): §II token names/values · one definition per
status · permitted alpha suffixes · no literal outside `:root` · no
color-bearing inline style · exactly four keyframes, all stoppable · animation
selector names a live referent · pure `#000`/`#fff` · background gradients ·
centered body text · type floor · pictographs · shadow loci · governing-source
header · 011 artifact frozen.

**Inventory** (judgment): mono-vs-sans role per text node · the 100 re-pointed
border/text sites · status-color-on-a-non-status-element as a semantic call ·
elevation-vs-decoration for each shadow · empty-state wording · recovery-path
ranking and consequence hints · every API override exposed under its real option
name · ordinal zero-padding · identifier ellipsis · record-block adoption ·
reduced-motion legibility · one-entity-one-detail-view click targets.

**Unassigned: none.** A rule appearing in neither list is a spec defect, not a
pass. The inventory's own header restates this partition so a reviewer can check
it without reading this file.
