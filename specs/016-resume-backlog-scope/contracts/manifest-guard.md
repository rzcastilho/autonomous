# Contract: manifest scope guard + refusal event

**Feature**: `016-resume-backlog-scope`

Extends `specs/009-crash-recovery/contracts/run_manifest.md`. `RunManifest`
remains a best-effort, never-fatal writer; this adds one refusal rule and one
run-level telemetry event.

## `RunManifest.write/1`

```elixir
@spec write(map()) :: :ok
```

Return type unchanged: **always `:ok`**, refusal included (FR-014 — persistence
never takes down a run).

### Decision table

Let `recorded = ids of the record currently at the resolved segment path` and
`proposed = ids in the write`.

| Existing record | `recorded -- proposed` | Action |
|-----------------|------------------------|--------|
| absent | — | write |
| unreadable / corrupt | — | write (nothing provable to lose) |
| present | `[]` | write |
| present | `[…]` non-empty | **refuse**: leave the file byte-identical, emit the event below, return `:ok` |

Comparison is over feature **ids** as a set. A write holding the same count but
a different member is refused (FR-011, SC-004). A write holding a **superset** is
always allowed — growth is not narrowing (US3's confirmed rebuild relies on this).

### Supersede

The guard has no bypass flag. A deliberately fresh run supersedes by calling
`RunManifest.clear/0` first, which `run/1` does when `supersede: true` (its
default). Resume paths pass `supersede: false` and therefore write **into** the
existing chain, where the guard applies (FR-013).

```text
run(supersede: true)  ─ clear/0 ─ write(A,B,C) ─ write(A,B,C) …      # fresh run
resume(...)           ─ (no clear) ─ write(A,B,C) …                  # continuation
resume(...) buggy     ─ (no clear) ─ write(A) ─▶ REFUSED             # this feature
```

### Ordering

The guard read happens before `File.mkdir_p!/1` and `File.write!/2`. The existing
`rescue _ -> :ok` still wraps the whole body, so a guard-read failure degrades to
"write proceeds", never to a raise.

## Event `[:speckit, :run, :scope_narrowing_refused]`

| Part | Key | Type | Notes |
|------|-----|------|-------|
| measurements | `dropped_count` | `pos_integer()` | `length(dropped)` |
| metadata | `segment` | `String.t() \| nil` | `nil` for the legacy flat bucket |
| metadata | `recorded` | `[String.t()]` | sorted; the surviving record's ids |
| metadata | `attempted` | `[String.t()]` | sorted; the refused write's ids |
| metadata | `dropped` | `[String.t()]` | sorted; `recorded -- attempted` |

Emitted exactly once per refused write. Never emitted on a successful write.

### Consumers (FR-012)

| Consumer | Behaviour |
|----------|-----------|
| `Telemetry.events/0` | includes the name, so every existing attacher picks it up with no extra wiring |
| `Telemetry.handle_event/4` | `Logger.warning("run scope narrowing refused: dropped=… recorded=… segment=…")` |
| `ConsoleReadModel.apply_event/4` | pushes `%{feature_id: nil, phase: nil, severity: :warn, text: "scope narrowing refused — would drop 002, 003"}`; `features` untouched |
| `ConsoleProjection.broadcast_diff/4` | broadcasts `{:console, :feed, entry}` on `"console:run"`; **no** `:feature_updated` (run-level) |

## Invariant proved by this contract

> Within one write chain (between two `clear/0` calls), the recorded feature set
> is monotonically non-shrinking.

Which yields SC-004: no sequence of operations other than a deliberate new run
can cause a live run's recorded feature to stop being recorded.
