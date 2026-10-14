# Contract: Console surfaces (042 delta over 040)

Supersedes the **Body** and **Truncation** bullets of
`specs/040-live-agent-conversation/contracts/console-surfaces.md`; every other
040 bullet (routes, catch-up notice, end marker, follow toggle, sticky
toolbar, empty states, next-session link, embed switching) stands unchanged
(FR-022). All markup obeys `docs/design-constitution.md`; the design-contract
guard keeps its rule count (SC-008).

## Routes / address

| Route | New param |
|---|---|
| `/live`, `/live/:conversation_id` | `frames=all` — show all frames; combines with `follow=1` |
| `/transcripts?run_id=&feature=&attempt=&session=` | `frames=all` |

Embedded Mission Control panel: toggle in place, no URL (like follow).

## Toolbar (sticky top) — additions

- `show all frames` switch (`.pr-toggle` + `.switch-input`, same as follow),
  `phx-click="toggle_frames"`, `data-frames={"all" | "default"}`.
- Header line appends, mono, each only when known:
  `<model_alias>` · `<model_resolved>` · `cli <cli_version>`
  (`[data-header-model]`, `[data-header-resolved]`, `[data-header-cli]`).

## Body blocks (`#conversation-rows`, `phx-update="stream"`)

Each block: `<div class="conv-row" data-class={row_class} data-flag=…>`.

| class | markup |
|---|---|
| `prose` | eyebrow `assistant` (faint mono); body via `TranscriptMarkup` in `.conv-prose` (sans), open |
| `context` | `<details>`; summary = eyebrow (`prompt` / `context`) + first line (sans for prompt text, mono for skill context); body plain text |
| `thinking` | `<details>`; summary `thinking` + first line; empty text ⇒ summary only, no disclosure body |
| `call` | `<details class="conv-call">`; summary = one mono line `Tool(summary)` (single line, ellipsized); body = pretty JSON input. Below, when paired: `.conv-result` with first 5 lines (`<pre>`, mono) and `+N lines` button (`phx-click="expand" phx-value-seq={result.seq}`); `.conv-flag` `is_error: true` when error; `.conv-flag` `unfinished` when tagged |
| `result` | standalone result (call not in view): eyebrow `tool result · <tool_name>` + same `.conv-result` part |
| `marker` | one muted mono line `<sub-kind> · key values` (task: description / status · summary; api_retry: `attempt a/max · error · delay ms`; hook: `hook_name · exit N` + flag `hook failed`; result: `subtype` + flag `result error`); longer payload in `<details>` |
| `divider` | thin rule with centered-left mono text `session opened · <model_alias>` |
| `end` | 040 end marker (outcome chip with `data-status`) unchanged |
| `raw` | `<details>`; summary label `<kind> · <sub-kind>`; body pretty JSON (only rendered when `frames=all`, or for unknown kinds always) |

040 truncation (40 lines / 4,000 chars, `… omitted` + `expand`) still applies
inside every folded body.

## Status line (sticky bottom) — new

`<section class="conv-status" role="region" aria-label="session status" data-conv-status>`,
`position: sticky; bottom` of the view's scroll container (page or
`.mc-live-panel`), mono, `flex-wrap` groups:

| group | attribute | text |
|---|---|---|
| activity | `[data-activity]` | status dot (`data-status` name: `running` while live, outcome chip name after end; pulse only while live) + `activity_text` |
| turns | `[data-turns]` | `turns 7` / `turns ≥ 7` |
| tools | `[data-tools]` | `tools 212` / `tools ≥ 212` |
| background | `[data-tasks]` | `bg 1` — only when > 0 |
| elapsed | `[data-elapsed]` | `12m 04s` — ticks 1/s while live, frozen at end |
| rate limit | `[data-rate-limit]` | `rate limit · five_hour · resets 14:30` — only while limited |
| cost/duration | `[data-cost]`, `[data-duration]` | `$0.77` · `11m 56s` — only after a `result` |

Announcements: `<p class="sr-only" aria-live="polite" data-announce>` —
set to the outcome text at `end` and to `rate limited · <type>` at onset;
nothing else.

Transcripts (`TranscriptsLive`): same status line, static (no tick, no pulse),
folded over all pages loaded so far.

## Events

| event | where | effect |
|---|---|---|
| `toggle_frames` | live, embedded, transcripts | flip `all_frames?`; rebuild rows from window / loaded pages; patch URL (`frames=all`) except embedded |
| `expand` (`seq`) | all | 040 semantics; for a result seq, replaces its owning call block in place |
| `:tick` (info) | live only | every 1,000 ms while `live? and not ended`; re-renders status line only |

## Join sequence (live)

`subscribe → catch_up → Conversation.file_path/1 → ConversationFile.fold(…, through_seq: last_seq)`
seeds `SessionStatus` (error ⇒ seed from window, `lower_bound?`) →
broadcasts `seq > last_seq` apply to both rows and status. Runs once per
attach / reconnect, never from a listing.
