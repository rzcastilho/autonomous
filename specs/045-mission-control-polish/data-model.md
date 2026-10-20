# Data Model: Mission Control Polish

No persisted entity changes: no Mnesia table, schema version, conversation
file format or run record is touched.

## Telemetry visibility preference (client)

| Field | Where | Values | Default |
|-------|-------|--------|---------|
| `autonomous.mc.telemetry` | browser `localStorage` | `"hidden"` \| `"shown"` | absent ⇒ shown |

- Written only by the `TelemetryPref` hook on a `telemetry_pref` push event.
- Read only on hook `mounted()`; any value other than `"hidden"`, a missing key,
  or a throwing storage accessor ⇒ shown (FR-005, edge case "storage
  unavailable").
- Per browser; never sent to the store, never shared between operators.

## `MissionControlLive` assigns

| Assign | Type | Change |
|--------|------|--------|
| `telemetry_hidden?` | `boolean` | **new**, default `false` |
| `live_sessions` | `%{feature_id => conversation_id}` | **removed** (only fed the row link) |
| `view.feed` | list (≤ 200) | unchanged; keeps accumulating while hidden |
| `view.delayed?` | boolean | unchanged; rendered in feed column or main column |

State transitions (`telemetry_hidden?`):

```text
false --telemetry_hide--> true   (push telemetry_pref hidden: true)
true  --telemetry_show--> false  (push telemetry_pref hidden: false)
false --telemetry_restore{hidden: true}--> true   (no push; value came from storage)
any   --telemetry_restore{other}--> unchanged
```

## `ConversationLive` (embedded mode) assigns

| Assign | Embedded | `/live` |
|--------|----------|---------|
| `follow?` | always `true` (no toggle) | operator toggle, unchanged |
| `all_frames?` | always `false` (no toggle) | operator toggle, unchanged |
| `ctx` / `:rows` stream | configured, never filled | unchanged |
| `status` (`SessionStatus`) | updated per entry | unchanged |
| `header`, `conversation_id`, `live?`, `ended?`, `empty`, `not_reachable?` | unchanged semantics | unchanged |
