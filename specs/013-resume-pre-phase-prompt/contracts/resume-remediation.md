# Contract: resume/2 pre-phase remediation

The interface this feature exposes is the operator-facing `resume/2` surface plus
the internal remediation-step behavior it drives. This is a CLI/iex-invoked
library, so the contract is the function signature, its option semantics, and the
observable side effects — not an HTTP schema.

## Public surface — `SpeckitOrchestrator.resume/2`

```elixir
@spec resume(String.t(), keyword()) ::
        GenServer.on_start()
        | {:error, {:unknown_feature, String.t()}}
        | {:error, :no_checkpoint}
        | {:error, :corrupt_checkpoint}
        | {:error, {:unknown_phase, term()}}
        | {:error, {:unknown_model, String.t()}}   # NEW
```

### New options (additive; all existing opts unchanged)

| Option | Type | Default | Semantics |
|--------|------|---------|-----------|
| `:remediation_prompt` | `String.t()` \| nil | `nil` | Operator remediation instruction. **Non-blank** ⇒ one remediation step runs before the target phase (FR-002). **Blank** (absent/`""`/whitespace) ⇒ no step; resume behaves exactly as today (FR-004). |
| `:remediation_model` | `"opus"` \| `"sonnet"` \| nil | `nil` | Model for the remediation step only. `nil` ⇒ `Config.model_for(target_phase)`. Unknown alias ⇒ `{:error, {:unknown_model, alias}}`, **no run started** (FR-011, Principle II). Does not change the target phase's model (FR-011). |

### Independence guarantees

- `:remediation_prompt` and the existing `:prompt` (feature-004 in-phase note)
  are **orthogonal**: supplying one does not change how the other is applied, and
  either may be supplied alone or together (FR-010).
- `:remediation_model` and per-phase model routing are orthogonal (FR-011).

## Behavioral contract — the remediation step

Given a resume at target phase `P` with a **non-blank** `:remediation_prompt`:

1. **Ordering** — exactly one remediation step executes, and it **completes
   before** phase `P` begins (FR-002/FR-003, SC-001).
2. **Artifact visibility** — phase `P` observes the worktree as the remediation
   step left it (FR-003).
3. **At-most-once** — no remediation step precedes any phase after `P`
   (FR-005/SC-003).
4. **Failure** — if the step fails after the same auto-retry a phase gets
   (`Config.phase_max_retries()` on a transient failure), the resume:
   - does **not** run phase `P`,
   - finalizes the feature `:failed`,
   - retains the worktree,
   - notifies the caller/coordinator (FR-006/SC-005).
5. **Re-divert** — if phase `P` re-runs and re-diverts (gate halt/escalation),
   normal terminal handling applies (worktree retained); the step does **not**
   auto-re-run (FR-007).
6. **Containment** — the step runs write-capable but under the same
   `scope_guard` hook as a phase; out-of-tree writes / dangerous Bash denied
   (FR-009).
7. **Cost** — the step's spend is recorded to the `Ledger`, counted toward the
   run budget and breaker (FR-008).
8. **Observability** — the step emits a `[:speckit, :phase]` telemetry span
   (`phase: :remediation`) and writes a durable `00-remediation.md` transcript
   (FR-012/SC-006).

Given a **blank** or absent `:remediation_prompt`:

9. **Zero overhead** — no remediation step, no extra model execution, no extra
   cost; the target phase executes directly, identical to a resume with no
   remediation (FR-004/SC-002).

## Internal contract — `PhaseRequest.build_remediation/3`

```elixir
@spec build_remediation(Feature.t(), model :: String.t(), keyword()) ::
        Jido.Harness.RunRequest.t()
# opts: :cwd (worktree path), :layout, and the operator :prompt (verbatim)
```

- Pure (no IO/CLI), unit-testable like `build/3`.
- `prompt` = framing header (feature id/slug + worktree-relative breakdown ref) +
  operator prompt verbatim.
- `model` = the caller-resolved remediation model (override → else target model).
- permissions = `%{permission_mode: :accept_edits, allowed_tools: ~w(Read Write
  Edit Bash Grep Glob)}` (FR-009).
- no `session_id` (fresh session).

## Internal contract — `Actions.RunRemediation` (`"remediation.run"` signal)

- `data: %{}` — reads `feature`, `worktree`, `layout`, `ledger`,
  `remediation_prompt`, `remediation_model` from agent state.
- Builds via `build_remediation/3`, runs the harness, folds a `PhaseResult`,
  resolves+records cost, and writes back `last_result` / `last_outcome`
  (`:ok` | `:error`) / a `%{phase: :remediation, …}` `history` entry / updated
  `cost_total`. Mirrors `RunFeaturePhase`'s state-fold shape; it does **not**
  decide control flow — `FeatureRunner` owns the proceed/stop decision.

## Test contract (hermetic)

- `FakeSDK` (`:jido_claude, :sdk_module`) drives the remediation harness call via
  a `:remediation` test scenario — same seam as the phase tests.
- The `:runner` / `:executor` facade seams still let `resume_test.exs` assert the
  opts are threaded without starting a real run.
