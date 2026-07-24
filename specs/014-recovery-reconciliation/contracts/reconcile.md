# Contract: `Recovery.Reconcile` (pure decision surface)

The whole repository-as-truth decision, side-effect free. Evidence is gathered
upstream (`Recovery.Evidence`) and passed in as arguments (Principle I). No git,
no file, no CLI here — this contract is unit-testable in isolation and MUST hold
>90% coverage.

## `status/3`

```elixir
@spec status(recorded :: Feature.status(), Evidence.t(), run_shape()) ::
        :done
        | {:resume, Pipeline.phase()}
        | :pending
        | :escalated
        | :halted
        | :failed
        | {:conflict, atom()}

@type run_shape :: {:breakdown, String.t()} | :ad_hoc
```

Multi-clause / pattern-matched, in this precedence:

1. **Human gates are inviolable.** `recorded ∈ {:escalated, :halted}` → returned
   unchanged, regardless of evidence. Recovery MUST NOT advance past a gate
   (FR-007, SC-004).
2. **`failed` stays failed.** `recorded == :failed` → `:failed` (US3).
3. **`done` requires corroboration.** `recorded == :done`:
   - evidence shows branch (and, PR-workflow, PR record) → `:done`.
   - no branch / no PR under normal operation → `{:conflict, :done_without_artifacts}`
     (FR-014 edge case).
4. **Non-terminal done-signal.** `recorded ∈ {:running, :pending}` and
   `done_signal?(evidence, shape)` → `:done` (FR-003).
5. **Non-terminal, mid-run.** `recorded == :running`, not a done-signal, branch
   has ≥1 boundary commit → `{:resume, phase_after(evidence.last_boundary_phase)}`
   (FR-004/FR-005).
6. **Never started.** `recorded == :pending`, no branch and no artifacts →
   `:pending` (FR-008).
7. **Contradictions.** `pr_record? and not branch_committed?` →
   `{:conflict, :pr_without_branch}`. Any residual ambiguity →
   `{:conflict, reason}` (FR-014) — never a silent guess.

### `done_signal?/2`

```elixir
@spec done_signal?(Evidence.t(), run_shape()) :: boolean()
```

- PR-workflow (`{:breakdown, _}` or a run whose context marks PR workflow):
  `evidence.pr_record? and evidence.branch_committed?` (FR-003).
- non-PR-workflow: `evidence.final_marker? and evidence.branch_committed?`.

The local PR record is authoritative; `evidence.pr_remote?` MUST NOT be *required*
for a `true` result — it only upgrades confidence and MUST never flip a local
`true` to `false` (offline-first, FR-018).

### `phase_after/1`

```elixir
@spec phase_after(Pipeline.phase() | nil) :: Pipeline.phase()
```

Returns the `Pipeline` phase following the latest committed boundary phase. If
the boundary is the terminal `:converge`, the caller reached clause 4 (done), not
clause 5. `nil` (no boundary commit) with `recorded == :running` is not a resume —
it is clause 6/7 (nothing committed ⇒ pending or conflict, per remaining
evidence).

## Invariants

- **Purity**: no clause performs I/O; identical inputs → identical output.
- **Gate safety**: no input combination advances `:escalated`/`:halted`.
- **No fabrication**: every non-terminal that is neither a clean done nor a clean
  resume nor a clean pending resolves to `{:conflict, _}` — the function never
  invents a done or a resume it cannot justify from evidence (FR-014, Principle II).
- **Offline**: output depends only on local-derivable fields; `pr_remote?` may be
  `:unknown` without changing a decision that local evidence already settles.
