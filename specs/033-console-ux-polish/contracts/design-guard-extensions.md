# Contract: Design-Guard Extensions (033)

`test/support/design_contract.ex` declares its rule set closed per
`specs/020-reconcile-console-design/contracts/design-guard.md` §5 (G-4). That
contract is a historical record of what 020 shipped and is not rewritten.
This document is the authority for every rule and allowlist change 033 makes.
The guard's moduledoc cites both documents.

**No rule is relaxed. No allowlist grows except as listed here.**

## A. Value changes (amendment of `docs/design-constitution.md` §II)

| Token | Old | New | Why |
|---|---|---|---|
| `--text-faint` | `#5a6274` | `#7a8296` | 2.85:1 on `--raised` → 4.53:1 (FR-038) |
| `--pending` | `#64748b` | `#94a3b8` | 3.47:1 in chip fill → 5.76:1 |
| `--blocked` | `#475569` | `#828ea3` | 2.25:1 in chip fill → 4.58:1 |
| `--failed` | `#f43f5e` | `#f6506a` | 4.32:1 in chip fill over `--raised` → 4.66:1 (found while building G-contrast; R8 missed it) |

`@contract_colors` changes these four values. The no-shared-values rule
still holds: none of the new values equals another token.

## B. Allowlist additions

| Allowlist | Addition |
|---|---|
| `:root` names | new `@layout_tokens ~w(--measure-transcript --rail-compact --card-min)` |
| `@derived_tokens` | `--border-input` |
| `@layout_named_values` | `52px` |

## C. New rules

Each rule has one injection that fires and one clean input that does not, in
`design_contract_test.exs`'s "required injections" block.

| Id | Scope | Fires when |
|---|---|---|
| G-contrast | `:root` block | any text token (`--text*`) below 4.5:1 on any surface token; any status token below 4.5:1 on its `1a` fill over `--card` and `--raised`; `--accent` below 3:1 on `--bg` (focus ring) |
| G-input | `.ex`/`.heex` surfaces | a `<select` or `<input` whose `type` is absent, `text`, `number` or `search` lacks `console-input` in its `class` |
| G-breakpoint | `console.css` | an `@media` with a `max-width`/`min-width` not in `~w(1120px 760px)` |
| G-inspect | `.ex`/`.heex` surfaces | `inspect(` inside a HEEx `{…}` interpolation in a `~H` sigil or `.heex` file |

Contrast uses the WCAG 2.x relative-luminance formula. Alpha fills are
composited over the surface before measuring.

## D. Not in scope of the guard

Judgment calls the guard cannot decide stay with review: short nav labels,
the casing rule, the empty-state wording, the gauge label format. They are
fixed in `contracts/console-surfaces.md` and checked by LiveView tests.
