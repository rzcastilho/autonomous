# Quickstart: validate 042

Prereqs: `mise trust mise.toml` done once; host toolchain via `mise exec --`.

## 1. Pure core (US1–US4 logic)

```bash
mise exec -- mix test test/autonomous/web/conversation_class_test.exs \
                      test/autonomous/web/tool_summary_test.exs \
                      test/autonomous/web/session_status_test.exs \
                      test/autonomous/web/conversation_rows_test.exs
```

Expected: every row of the placement table (`data-model.md`) asserted;
six-tool + unknown-tool summaries; status fold for each FR-015 transition,
idempotence by seq, freeze after `end`, `open_tasks` floor, nil cost before
`result`; parallel calls `[A+rA][B+rB]` with `rB` arriving first; SC-002
block-count identity with `all_frames: true`.

## 2. Surfaces

```bash
mise exec -- mix test test/autonomous/web/conversation_live_test.exs \
                      test/autonomous/web/transcripts_live_test.exs \
                      test/autonomous/web/mission_control_live_test.exs \
                      test/autonomous/web/design_contract_test.exs
```

Expected: no `[data-class=raw]` for status/thinking_tokens/hook/tool_progress/
rate-limit entries by default, all present with `?frames=all`; status line
groups (`[data-activity]`, `[data-turns]`, …) update from broadcast entries;
a join to a 600-entry session shows exact counters (file seed), and `≥` when
the file is removed; `:tick` advances `[data-elapsed]` and stops at `end`;
Transcripts shows the same blocks and final status line as the live end state
(SC-004); guard green with unchanged rule count (SC-008).

## 3. Census re-measure (opt-in, machine-local)

```bash
AUTONOMOUS_CENSUS_DIR=~/.autonomous/transcripts \
  mise exec -- mix test --only census test/autonomous/web/census_test.exs
```

Expected (2026-10-13 baseline, 91 files, 5,014 entries): default blocks
≤ 35% of entries (~1,708), every prompt/text/thinking/call/result visible,
every entry visible-or-signal, live-fold == saved-fold per file.

## 4. By hand (container or host console)

1. `scripts/autonomous console` (or `mise exec -- iex -S mix phx.server`), start
   any run with a short backlog feature.
2. Open `/live?follow=1`: transcript shows prose, folded prompt, `Bash(...)`
   lines with 5-line results; status line at the bottom reads
   `requesting` / `thinking · ~N tok` / `running Bash · 30s`, counters move,
   elapsed ticks.
3. Toggle **show all frames**: status/hook/heartbeat rows appear in place;
   URL gains `frames=all`.
4. Reload mid-session: elapsed continues from the real start; counters equal
   pre-reload values.
5. After the session ends: open its Transcripts entry — same blocks, static
   status line with turns/tools/duration/cost.
6. Mission Control embed: the status line pins to the panel's bottom edge;
   narrow the window below 760px — groups wrap, no horizontal scroll.
7. Screen reader (VoiceOver): only the outcome and a rate-limit onset are
   announced.
