# Contract: Resume Documentation Surface

The docs feature exposes no software interface. Its contract is the **frozen
`resume/2` surface** every runbook example must match verbatim (SC-002), plus the
**stale-reference invariant** (SC-003). Source of truth:
`lib/speckit_orchestrator.ex` `resume/2` (`@doc`/`@spec` ~lines 138–162). If that
signature changes, this contract and the runbook examples change with it.

## Signature (must appear byte-compatible in docs)

```elixir
@spec resume(String.t(), keyword()) ::
        GenServer.on_start()
        | {:error, {:unknown_feature, String.t()}}
        | {:error, :no_checkpoint}
        | {:error, :corrupt_checkpoint}
        | {:error, {:unknown_phase, term()}}
def resume(feature_id, opts \\ [])
```

## Canonical documented examples (SC-002 parity anchors)

Every `iex` snippet in the runbook resume section MUST be a syntactic instance of
these forms — same function name, arity, and option keys.

```elixir
# 1. Default: restart at the checkpointed (halted/escalated) phase
iex> SpeckitOrchestrator.resume("003")

# 2. With operator guidance injected into the resumed phase
iex> SpeckitOrchestrator.resume("003", prompt: "use Decimal for money, not float")

# 3. Restart earlier than the checkpoint (override start phase)
iex> SpeckitOrchestrator.resume("003", from: :plan)

# 4. Both options together
iex> SpeckitOrchestrator.resume("003", from: :plan, prompt: "re-plan around the money fix")
```

Only these option keys are valid in examples: `:from`, `:prompt`, plus inherited
`run/1` opts. No example may invent a key (e.g. `start_phase:`, `resume_prompt:` —
those are internal `FeatureRunner` opts, NOT the facade surface).

## Documented error outcomes (must be listed, each a no-run failure)

| Returned | Documented meaning |
|----------|--------------------|
| `{:error, {:unknown_feature, id}}` | feature id not in the backlog |
| `{:error, :no_checkpoint}` | feature never checkpointed → use `resolve/1` |
| `{:error, :corrupt_checkpoint}` | checkpoint unreadable → use `resolve/1` |
| `{:error, {:unknown_phase, term}}` | bad `:from` (or corrupt stored phase) |

## Invariants (verification contract)

- **INV-1 (SC-002 parity)**: every documented `resume(...)` call and error tuple
  matches the `@spec` above — checked by diffing docs against
  `lib/speckit_orchestrator.ex`.
- **INV-2 (SC-003 zero-stale)**: `grep -rniE 'mid-pipeline resume is v2|v2 concern|resume[^.]*(is|a)[^.]*(future|v2)' --include='*.md' .`
  (excluding `specs/`) returns no match. Source `.ex` docstrings are excluded by
  construction (`--include='*.md'`).
- **INV-3 (docs-only)**: `git diff --name-only` for the implementation change
  touches only `.md` files — no `lib/`, `test/`, `config/`, or `mix.exs`.
