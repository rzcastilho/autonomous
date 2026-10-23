# Contract: Configuration page — "container engine" row

**Placement**: The row goes in the same `<dl>` as the "agent root" row
(`ConfigLive`), immediately after it.

**Visibility**: The row renders only when `ContainerEngine.requested?/0`. When
the engine was not requested:
- no `<dt>` or `<dd>` is rendered;
- no async probe is started;
- the page markup is byte-identical to before this feature (FR-014, SC-004).
  `config_live_test` compares it against the pre-046 rendering.

**Markup** (shape; classes are reused, no new tokens):

```heex
<dt :if={@container_engine != :hidden}>container engine</dt>
<dd :if={@container_engine != :hidden} class="config-instance-id" data-container-engine>
  {ContainerEngineView.summary(@container_engine)}
</dd>
```

**State source**: The value comes from `refresh/1`.
- **Requested:** the state is `:checking`, and `start_async(:container_engine,
  fn -> ContainerEngine.probe([]) end)` runs.
- **Probe returns `{:ok, v}`:** `{:available, v}`.
- **Probe returns `{:error, c}`:** `{:unreachable, c}`.
- **Probe task exits:** `{:unreachable, "the engine probe crashed — reload to
  retry"}`.

**Rendered text** (`ContainerEngineView.summary/1`, pure, no `inspect/1`):

| State | Text |
|---|---|
| `:checking` | `checking…` |
| `{:available, v}` | `available — engine <v>` |
| `{:unreachable, c}` | `unreachable — <c>` |

**Truthfulness**: The row never shows `available` without a probe from this
render cycle (Principle VII, User Story 4.2). The version is machine output and
renders in the mono family, through the existing `config-instance-id` class.
