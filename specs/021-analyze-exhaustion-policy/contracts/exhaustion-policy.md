# Contract: Exhaustion Policy — setting, signals, gate

**Feature**: `021-analyze-exhaustion-policy`

Covers the setting's public surface (§1), its validation and refusal shapes
(§2), how it reaches the gate (§3), the gate's amended decision table (§4), and
the launch control (§5). The record the *proceed* path produces is a separate
contract: `advanced-record.md`.

---

## 1. The setting

### 1.1 `SpeckitOrchestrator.Remediation.Settings`

```elixir
@type policy :: :escalate | :proceed

defstruct enabled?: true,
          threshold: :high,
          attempt_limit: 2,
          model: nil,
          exhaustion_policy: :escalate

@type t :: %__MODULE__{
        enabled?: boolean(),
        threshold: Severity.severity(),
        attempt_limit: 1..5,
        model: String.t(),
        exhaustion_policy: policy()
      }
```

### 1.2 `SpeckitOrchestrator.Config`

```elixir
@doc "The default exhaustion policy for a run that does not choose one (FR-002)."
@spec auto_remediation_exhaustion_policy() :: Remediation.Settings.policy()
def auto_remediation_exhaustion_policy,
  do: get(:auto_remediation_exhaustion_policy, :escalate)
```

`config/config.exs` documents the key alongside the other three
`auto_remediation*` keys. The shipped value is `:escalate`.

### 1.3 `SpeckitOrchestrator.RunContext`

Ninth field, string-valued in the manifest:

```elixir
auto_remediation_exhaustion_policy: String.t() | nil
```

- `capture/1` — `Keyword.get(opts, :auto_remediation_exhaustion_policy,
  Config.auto_remediation_exhaustion_policy()) |> stringify_policy()`
- `to_map/1` — `"auto_remediation_exhaustion_policy" => ctx.auto_remediation_exhaustion_policy`
- `from_map/1` — `Map.get(map, "auto_remediation_exhaustion_policy")`
- `@keys` — extended, so `merge/2` reapplies it on resume with the existing
  `explicit opts > recorded > (absent → live Config)` precedence

`stringify_policy/1` mirrors `stringify_threshold/1`: atom → string, string
passes through, `nil` stays `nil`. Only ever atom → string, never the reverse.

### 1.4 `run/1` option

```elixir
SpeckitOrchestrator.run(auto_remediation_exhaustion_policy: :proceed)
```

Accepted as an atom or a string; documented in the facade's option list beside
the other three loop knobs, which become "the five `auto_remediation*` keys" in
the `RunContext` docstrings.

---

## 2. Validation and refusals

### 2.1 Parser

```elixir
@spec parse_policy(term()) :: {:ok, policy()} | :error
```

| Input | Result |
|---|---|
| `:escalate`, `:proceed` | `{:ok, same}` |
| `"escalate"`, `"proceed"` (any case) | `{:ok, atom}` |
| `nil` | handled by the caller's default, not by the parser |
| anything else | `:error` |

MUST NOT call `String.to_atom/1`. Matching is on downcased literals, exactly as
`Severity.parse/1` does.

### 2.2 `Settings.validate/1`

Field order is unchanged and the new check is appended last, so no existing
refusal changes which error it reports:

```
enabled?  →  threshold  →  attempt_limit  →  model  →  exhaustion_policy
```

New error member:

```elixir
{:error, {:invalid_exhaustion_policy, value}}
```

Rules (FR-010): never clamps, never substitutes the default for a bad value,
never partially applies. An **absent** field takes the default `:escalate`; a
**present but invalid** field errors.

### 2.3 `Settings.from_context/1`

All three clauses (`nil`, `%RunContext{}`, string/atom-keyed map) resolve the
new field with the same `default(value, :escalate)` tolerance the other fields
use.

### 2.4 Refusal surfaces

| Surface | Behaviour on an unrecognized value |
|---|---|
| `run/1` preflight (`preflight_remediation/1`) | `{:error, {:preflight, [{:invalid_exhaustion_policy, value}]}}`; **no run starts**, no `Coordinator`, no store row (SC-007) |
| `resume/2` | same preflight, same refusal |
| Console launch form | `<.form_refusal label="Refused: auto-remediation-exhaustion-policy">` naming the offending value; no run dispatched (FR-013) |
| Recorded-but-invalid value reaching `FeatureRunner` | `remediation_settings!/1` raises — a corrupt manifest, not operator input (existing behaviour, unchanged) |

---

## 3. Signal flow

```
Config default / run opt
   └─ RunContext.capture/1 ──► run_settings (Mnesia)  ──► FR-014 display
        └─ Settings.from_context/1 (once per feature run, from the CAPTURED context)
             ├─ AnalyzeRunner  ── loop unchanged ──► exhaustion_signals/3
             │                                         └─ signals.exhausted? = true
             └─ FeatureRunner.gate_signals(:analyze, …)
                                                       └─ signals.exhaustion_policy
                                                            │
                                                            ▼
                                              Pipeline.next(:analyze, :ok, signals)
```

### 3.1 `AnalyzeRunner`

`exhaustion_signals/3` gains one key on the exhaustion branch only:

```elixir
defp exhaustion_signals(signals, _state, nil), do: signals    # unchanged

defp exhaustion_signals(signals, state, attempts) do
  signals
  |> Map.put(:remediation, %{attempts: attempts, limit: state.settings.attempt_limit,
                             exhausted?: true})   # unchanged
  |> Map.put(:exhausted?, true)                   # new
end
```

The disabled short-circuit (`run/1`'s `enabled?: false` clause) is untouched, so
with the loop off no exhaustion signal is ever produced and the policy is inert
for either value (FR-015).

### 3.2 `FeatureRunner.gate_signals/3`

```elixir
defp gate_signals(:analyze, st, step_opts) do
  signals = st.last_signals || %{}

  case Map.get(step_opts, :remediation_settings) do
    %Settings{threshold: threshold, exhaustion_policy: policy} ->
      signals
      |> Map.put(:gate_threshold, threshold)
      |> Map.put(:exhaustion_policy, policy)

    _absent ->
      signals
  end
end
```

Every other phase's signals still pass through untouched.

---

## 4. The amended gate — `Pipeline.next(:analyze, :ok, signals)`

### 4.1 Decision table

| # | Condition | Outcome | Requirement |
|---|---|---|---|
| 1 | `critical? == true` | `{:halted, :critical_finding}` | FR-005, SC-003 |
| 2 | `high? == true`, `not at_or_above?(:high, gate_threshold)` | `{:cont, :implement}` | 017 (unchanged) |
| 3 | `high? == true`, `exhausted? == true`, `exhaustion_policy == :proceed` | `{:cont, :implement}` | FR-004 |
| 4 | `high? == true` | `{:escalated, :high_findings}` | FR-003 |
| 5 | otherwise | `{:cont, :implement}` | unchanged |

Row 1 is a separate function clause and is matched before any policy is read —
the Critical halt is structural, not conditional (FR-005). Rows 2–4 live in one
`cond` inside the existing `high?` clause.

### 4.2 Defaults

```elixir
defp exhausted?(signals),         do: Map.get(signals, :exhausted?, false)
defp exhaustion_policy(signals),  do: Map.get(signals, :exhaustion_policy) || :escalate
```

With both absent, rows 2/4/5 reproduce the pre-021 gate byte-for-byte. This is
the mechanism behind FR-002 and SC-002 — there is no separate legacy path to
keep in sync.

### 4.3 Invariants (property-tested)

- **I1** — for every `threshold` and every `policy`, `critical? == true` ⇒
  `{:halted, :critical_finding}`. (SC-003)
- **I2** — for every signal map with `exhausted?` absent or `false`, the
  outcome equals the pre-021 outcome for the same map. (SC-002)
- **I3** — for `policy == :escalate`, the outcome equals the pre-021 outcome
  for the same map, exhausted or not. (FR-003)
- **I4** — the policy never changes a non-`:analyze` phase's outcome, and never
  changes an `:analyze` outcome when `outcome == :error`. (FR-006)

### 4.4 What the gate does NOT do

Row 3 produces an ordinary `{:cont, :implement}`. It does not attach findings to
the transition, does not alter the phase request, and does not set any flag a
downstream phase reads. Everything after analyze runs byte-identically to a
clean-analyze advance (FR-004a).

---

## 5. Launch control (`TriggerLive`, FR-013)

### 5.1 Assign

```elixir
remediation_exhaustion_policy: to_string(Config.auto_remediation_exhaustion_policy())
```

Pre-filled from the configured default on every mount, so a previous run's
choice never becomes the next launch's default (FR-012, User Story 2
scenario 4).

### 5.2 Markup

Added inside the existing `#auto-remediation-form`, after "Attempt limit",
using the existing `field-label-inline` class — no new class, no new token:

```heex
<label class="field-label-inline">
  On exhaustion
  <select name="exhaustion_policy" data-exhaustion-policy disabled={not @auto_remediation?}>
    <option value="escalate" selected={@remediation_exhaustion_policy == "escalate"}>
      escalate
    </option>
    <option value="proceed" selected={@remediation_exhaustion_policy == "proceed"}>
      proceed
    </option>
  </select>
</label>
```

Option labels are the real setting values (`escalate` / `proceed`), not friendly
synonyms — Principle VII, "the UI speaks the system's vocabulary". The control
is disabled with the rest of the group when auto-remediation is off, matching
FR-015's "no observable effect".

### 5.3 Events

- `"update_remediation"` also reads `params["exhaustion_policy"]`, falling back
  to the current assign.
- `start_opts/1` adds `auto_remediation_exhaustion_policy: settings.exhaustion_policy`
  to the opts it passes to `run/1` — opts only, so the node's configured default
  is untouched for the next mount (FR-012).
- `validate_remediation/1` maps the new error to
  `{"auto-remediation-exhaustion-policy", "Unrecognized exhaustion policy: #{value}"}`,
  rendered by the existing `<.form_refusal>`.

---

## 6. Compatibility

| Surface | Change |
|---|---|
| `Feature` status enum | none |
| `Pipeline.transition()` | none |
| `Remediation.next/2` decision table | none |
| `Remediation.terminal_reason/2` | none |
| `AnalyzeRunner` loop control flow | none — one added signal key on one branch |
| Cost accounting / breaker precedence | none (FR-006, SC-006) |
| Checkpoint shape | none |
| Existing `signals.remediation` map | none |
