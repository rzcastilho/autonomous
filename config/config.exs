import Config

# Keep test output readable — the runner logs a line per phase transition.
if config_env() == :test do
  config :logger, level: :warning

  # Durable transcripts default to a repo-relative sibling dir; in tests pin them
  # to a tmp path so runs that drive FeatureRunner/Transcripts don't write into
  # the real ../.speckit-transcripts.
  config :speckit_orchestrator,
    transcript_root: Path.join(System.tmp_dir!(), "speckit_test_transcripts")
end

# ---------------------------------------------------------------------------
# jido_harness provider registration
#
# Phase 0 finding: this harness version does NOT auto-discover adapters.
# `Jido.Harness.providers/0` returns [] until providers are configured
# explicitly (see deps/jido_harness/lib/jido_harness/registry.ex). This
# overturns CONFIRM #1's "likely unnecessary" — explicit config IS required.
# ---------------------------------------------------------------------------
config :jido_harness,
  providers: %{claude: Jido.Claude.Adapter},
  default_provider: :claude

# ---------------------------------------------------------------------------
# jido_action execution timeout. The default is 30s (jido_action Exec), which
# kills a phase action mid-CLI-run — Spec Kit phases take minutes (implement
# runs up to `implement_max_turns` turns). Raise the ceiling to cover the
# longest phase; the outer `FeatureRunner` AgentServer.call timeout is kept
# strictly larger so the action timeout is the governing guard, not the call.
# Per-phase timeouts are a future tuning knob (runbook §6).
# ---------------------------------------------------------------------------
config :jido_action, default_timeout: :timer.minutes(45)

# ---------------------------------------------------------------------------
# speckit_orchestrator — orchestrator configuration (Phase 1 consumes these
# via SpeckitOrchestrator.Config). Model values are FULL model strings, not
# CLI aliases, for reproducibility (user decision). Placeholders below are
# documented as such — verify against the org allowlist in the Phase 2 spike:
#   claude --model <string> -p "print your model id"
# ---------------------------------------------------------------------------
config :speckit_orchestrator,
  # Path to the repo the orchestrator drives (the target Spec Kit repo).
  repo: ".",
  # Where NNN-*.md feature breakdown files live, relative to :repo.
  breakdown_dir: "docs/breakdown",
  # Root under which per-feature git worktrees are created.
  worktree_root: "../.speckit-worktrees",
  # Per-phase model routing. Phase 3 finding: the pinned ClaudeAgentSDK validates
  # `model` against its bundled catalog, which accepts ALIASES (opus/sonnet/haiku,
  # plus opus[1m]/sonnet[1m]) — full current strings like "claude-opus-4-8" are
  # NOT in the catalog and fail validation. For reproducibility, pin the alias->
  # full-model mapping via the ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL env
  # vars (forwarded by the adapter runtime contract), not by putting full strings
  # here. See docs/harness-contract.md.
  models: %{
    specify: "sonnet",
    clarify: "opus",
    plan: "opus",
    tasks: "sonnet",
    analyze: "opus",
    implement: "sonnet",
    converge: "sonnet"
  },
  # Ordered plan stack passed to the plan phase. The LedgerLite spec deliberately
  # delegates language/format to plan, so plan cannot proceed without one — this
  # is the product/tech decision the pipeline can't derive.
  plan_stack: [
    "Python 3 (standard library only: argparse, unittest; no third-party dependencies)"
  ],
  # Max features running concurrently (worktree-level parallelism).
  max_concurrency: 2,
  # Stacked sequential PR workflow (off by default). When true, `run/1` forces
  # cap 1, requires the `:pr_remote` remote on the target, stacks each feature on
  # the previous feature's branch, and opens a PR per feature on :done.
  pr_workflow: false,
  # Root base branch for the first feature's PR; later features stack on the prior.
  pr_base: "main",
  # Remote to push feature branches to (and preflight) in the PR workflow.
  pr_remote: "origin",
  # Cost circuit-breaker budget for a run, in USD. Sized to ~5 features' worth
  # of the recalibrated per-feature estimate (~$14.82) so the breaker drill trips
  # mid-run over the 7-feature LedgerLite backlog (plan §7.2 trap 3). Raise for a
  # non-drill run that should complete all 7 (>~$104).
  budget_usd: 74.0,
  # Turn cap for the long-running implement phase.
  implement_max_turns: 80,
  # Retries for a phase that fails transiently (server/API drop, incomplete
  # stream) before the feature is failed. Real errors are never retried.
  phase_max_retries: 1,
  # Per-phase USD cost estimates. Used as a FALLBACK only — the Claude adapter
  # emits a :usage event with actual cost_usd when the CLI reports
  # total_cost_usd; the estimate is recorded when it does not.
  #
  # Recalibrated 2026-07-15 from a live single-phase smoke: `/speckit.specify`
  # for feature 001 cost $0.63 actual vs the old $0.20 estimate (3.15x under).
  # `specify` is the one measured phase; the rest are the old estimates scaled by
  # that 3.15x factor — PROVISIONAL, refine after a full-pipeline live run
  # (esp. `implement`, which dominates and is the least like `specify`).
  # Per-feature sum ~= $14.82.
  cost_estimates: %{
    specify: 0.63,
    clarify: 1.26,
    plan: 1.89,
    tasks: 0.95,
    analyze: 1.26,
    implement: 7.88,
    converge: 0.95
  },
  # Pinned Spec Kit CLI tag (drift diagnosis — plan §4.6).
  speckit_version: "v0.12.11"
