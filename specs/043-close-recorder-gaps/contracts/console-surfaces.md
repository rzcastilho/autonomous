# Contract: Console Surfaces (feature 043)

Delta over `specs/042-classify-conversation-output/contracts/console-surfaces.md`.
Applies identically to the `/live` conversation page, the Mission Control
embedded panel, and Transcripts (saved conversation); all three already fold
entries through the same pure modules, so parity is structural.

## Rows

| entry | default view | `frames=all` |
|---|---|---|
| `stderr` line | one-line quiet row: `stderr` label + mono line text; a run of identical consecutive lines shows once with `×N` | same (toggle has no effect) |
| `stderr` notice | marker row `stderr · <n> lines dropped` | same |
| `usage` | hidden (status-line signal) | raw row `usage · message_start\|message_delta` |
| `result`, `is_error` | marker row `result · <subtype> — <error>` or `— no reason given`, status `failed` styling (042 `:result_error` flag) | same |
| entries with `parent_tool_use_id` | rendered exactly as without it | same |

stderr rows sit where they were recorded; in a flooded session the tail lines
follow the notice after the last frame. No surface claims exact wall-clock
interleaving of stderr and frames.

## Status line (footer)

Adds one field, placed after turns and before cost:

```
<activity> · <elapsed> · <turns> turns · in 12.1k · out 3.1k · $0.42
```

- token field absent until the first `usage` entry (never `in 0`);
- `≥` prefix when the status is a window-only lower bound (042 rule);
- cost absent until the `result` reports `cost_usd` (unchanged 042 rule; no
  estimate);
- an error result sets activity text `result error — <error>`;
- end-state outcome: chip from the `end` entry, except `done` + recorded result
  error ⇒ chip `failed`, text `<outcome> · result error`.

## Version handling

A conversation file with version ≥ 3 shows the existing unsupported-version
notice naming the version; nothing partial is rendered.

## Design contract

Tokens only, mono for machine text (stderr lines, token figures), no new tokens,
keyframes or breakpoints; `design_contract_test` rule count unchanged (SC-008).
