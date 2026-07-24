defmodule SpeckitOrchestrator.FeatureAgent do
  @moduledoc """
  A Jido agent owning one feature's run.

  It is a passive state holder: the `FeatureRunner` drives it synchronously via
  `Jido.AgentServer.call/3`, one signal per phase. State fields:

    * `feature` / `worktree` / `ledger` — seeded by `feature.init`.
    * `layout` — the run's resolved `%Layout{}` (FR-011, 012), seeded by
      `feature.init`; threaded into `PhaseRequest.build/3` for the
      worktree-relative breakdown ref.
    * `phase` — the phase last run.
    * `resume_phase` — the phase the run started at (fixed at init, unlike
      `phase` which advances); `resume_prompt` — an optional operator note
      carried alongside it. Both are a stable anchor for future prompt
      injection (state only — no phase request is altered by this feature).
    * `session_id` — Claude session id, carried forward for resume.
    * `status` — `:pending → :running →` terminal (`:done | :escalated |
      :halted | :failed`), set by `feature.finalize`.
    * `last_outcome` / `last_signals` / `last_result` — the most recent phase
      run, consumed by the runner to compute `Pipeline.next/3`.
    * `history` — reverse-chronological per-phase entries.
    * `cost_total` — accumulated recorded spend for this feature.
  """

  use Jido.Agent,
    name: "feature",
    description: "Owns a single feature's Spec Kit pipeline run",
    schema: [
      feature: [type: :any, default: nil],
      worktree: [type: :any, default: nil],
      ledger: [type: :any, default: nil],
      layout: [type: :any, default: nil],
      phase: [type: :atom, default: nil],
      resume_phase: [type: :atom, default: nil],
      resume_prompt: [type: :string, default: nil],
      remediation_prompt: [type: {:or, [nil, :string]}, default: nil],
      remediation_model: [type: {:or, [nil, :string]}, default: nil],
      session_id: [type: :string, default: nil],
      status: [type: :atom, default: :pending],
      last_outcome: [type: :atom, default: nil],
      last_signals: [type: :map, default: %{}],
      last_result: [type: :any, default: nil],
      terminal_reason: [type: :any, default: nil],
      history: [type: {:list, :any}, default: []],
      cost_total: [type: :float, default: 0.0]
    ],
    signal_routes: [
      {"feature.init", SpeckitOrchestrator.Actions.InitFeature},
      {"phase.run", SpeckitOrchestrator.Actions.RunFeaturePhase},
      {"remediation.run", SpeckitOrchestrator.Actions.RunRemediation},
      {"feature.finalize", SpeckitOrchestrator.Actions.FinalizeFeature}
    ]
end
