# Autonomous workflow

End-to-end flow of the `speckit_orchestrator` autonomous, spec-driven build
pipeline: operator → control plane (Coordinator + Ledger) → per-feature data
plane (the 7-phase Spec Kit pipeline) → terminals → human-resolve loop.

```mermaid
flowchart TB
  OP([Operator · iex]) -->|SpeckitOrchestrator.run/0| BL[Load backlog<br/>docs/breakdown/NNN-*.md<br/>validate DAG · raises on cycle/dangling]
  BL --> CO{{Coordinator · per-run GenServer}}

  subgraph CTRL[Control plane]
    direction TB
    CO -->|release a wave| REL[Release.next_wave<br/>pending with prereqs done<br/>size = cap − in-flight]
    REL -->|breaker tripped?| LED[(Ledger · budget_usd<br/>reserve / record / trip)]
    REL -->|spawn per feature<br/>cap = max_concurrency| RUN[FeatureRunner<br/>Task under RunnerSup]
  end

  RUN -->|git worktree add<br/>feature/NNN-slug<br/>assert scaffold| WT[[Isolated worktree]]
  WT --> PIPE

  subgraph PIPE[Data plane · per-feature pipeline · claude CLI via jido_harness]
    direction TB
    SP[specify<br/>create-new-feature.sh → spec.md] --> CL[clarify<br/>Opus reviewer]
    CL -->|emits NEEDS HUMAN| GESC{material<br/>ambiguity?}
    GESC -->|yes| ESC(((escalated)))
    GESC -->|no · defaults applied| PL[plan<br/>setup-plan.sh + plan_stack → plan.md]
    PL --> TK[tasks<br/>→ tasks.md]
    TK --> AN[analyze<br/>vs constitution MUSTs]
    AN -->|Critical finding| GHALT{halt?}
    GHALT -->|yes| HALT(((halted)))
    GHALT -->|clean| IM[implement<br/>writes src + tests, self-commits]
    IM --> CV[converge] --> DONE(((done)))
  end

  PIPE -.each phase records cost.-> LED
  PIPE -.transcript per phase.-> TR[(Durable transcripts<br/>transcript_root NNN NN-phase)]

  DONE -->|Worktree.commit → REMOVE| BR[Reviewable branch<br/>plan/tasks/contracts + src + tests<br/>PR-ready]
  ESC -->|Worktree.commit → KEEP| KEPT[[Kept worktree<br/>for human]]
  HALT -->|Worktree.commit → KEEP| KEPT
  FAIL(((failed))) -->|Worktree.commit → KEEP| KEPT

  KEPT -->|human answers in<br/>breakdown Decisions<br/>commit on branch| RES[SpeckitOrchestrator.resolve/1<br/>frees worktree · keeps branch]
  RES -->|re-run reuses branch| CO

  LED -->|committed ≥ budget| BRK[Breaker trips<br/>release none · drain in-flight<br/>halt between phases]
  BRK --> REP
  DONE --> REP[[Final report<br/>done · escalated · halted · failed<br/>blocked · not_started · spend]]
  ESC --> REP
  HALT --> REP

  classDef term fill:#1f6feb,stroke:#0b3d91,color:#fff;
  classDef gate fill:#b45309,stroke:#7c2d12,color:#fff;
  classDef sink fill:#166534,stroke:#052e16,color:#fff;
  class ESC,HALT,DONE,FAIL term;
  class GESC,GHALT gate;
  class BR,REP sink;
```

## Reading it

- **Control plane** (`Coordinator` + `Ledger`) is pure orchestration: it releases
  features in dependency-and-cap **waves**, records cost per phase, and trips the
  **breaker** at `budget_usd` (drain-don't-kill — in-flight features finish their
  current phase then halt).
- **Data plane** is the Spec Kit loop run through the `claude` CLI, one phase per
  fresh `claude -p` session, in an isolated **git worktree** per feature.
- **Two gates** divert the linear pipeline: `clarify` escalates on a *material*
  `## NEEDS HUMAN` (→ `escalated`); `analyze` halts on a Critical constitution
  violation (→ `halted`).
- **Terminals commit before teardown.** `:done` commits the generated branch then
  removes the worktree; `escalated`/`halted`/`failed` commit then **keep** the
  worktree. Transcripts are written to a **durable** root that survives teardown.
- **Human-resolve loop.** For a kept feature, answer the escalation in the
  breakdown's `## Decisions` (specify regenerates the spec from it), commit on the
  branch, `resolve/1` to free the worktree, and re-run — the feature reuses its
  branch. Escalations can span multiple rounds.

See `docs/runbook.md` for the operator step-by-step and
`docs/speckit-orchestrator-implementation-plan.md` for scope and rationale.
