# Contract: Configuration page — declared volumes group (FR-023)

Governed by Principle VII and `docs/design-constitution.md`; guard rules in
`test/support/design_contract.ex` apply (no literals, no raw `inspect/1`,
shared input/fieldset classes).

## Modules

| Module | Kind | Responsibility |
|---|---|---|
| `Autonomous.AppliedVolumes` | pure (+ `current/0` env read) | `parse(nil \| "" \| json) :: {:ok, [Volume.t()], decl_path} \| {:error, reason}` |
| `Autonomous.VolumeUsage` | boundary IO | `measure(path, timeout_ms \\ 30_000) :: {:ok, bytes} \| {:unknown, reason}` via `du -sk -x` |
| `Autonomous.Web.VolumesView` | pure | view state (`data-model.md`), size formatting, labels |
| `Autonomous.Web.ConfigLive` | LiveView | assigns `volumes`; `start_async(:volume_usage, …)` on connected mount |

## Markup

Rendered only when state ≠ `:hidden`; a no-declaration instance's page is
byte-identical to today.

```heex
<fieldset class="config-volumes form-panel" data-volumes>
  <legend>declared volumes</legend>
  <p class="config-note">as applied at start — edits to <span class="mono">volumes.toml</span> since then are not shown</p>
  <p class="mono" data-volumes-declaration>{@declaration}</p>
  <table class="data-table">
    <thead><tr><th>name</th><th>mount path</th><th>variables</th><th>path dirs</th><th>space used</th></tr></thead>
    <tbody>
      <tr data-volume={v.name}> … <td data-volume-usage={usage_state}>…</td></tr>
    </tbody>
  </table>
</fieldset>
```

- Identifiers (name, path, `VAR=value`, dirs, declaration path) render mono,
  ellipsize, never renamed.
- `data-volume-usage`: `measuring` | `known` | `unknown`. Unknown text:
  `unknown (timed out)`, `unknown (not mounted)`, `unknown (du failed: …)` —
  never `0`.
- `{:refused, reason}` → `<.form_refusal label="AUTONOMOUS_VOLUMES unreadable">`.
- No animation (measuring is a text state, not a spinner).
- Reload re-measures (US4 scenario 3).
