import Config

# Keep test output readable — the runner logs a line per phase transition.
if config_env() == :test do
  config :logger, level: :warning
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
  # Ordered plan stack passed to the plan phase (documented placeholder).
  plan_stack: [],
  # Max features running concurrently (worktree-level parallelism).
  max_concurrency: 2,
  # Cost circuit-breaker budget for a run, in USD.
  budget_usd: 25.0,
  # Turn cap for the long-running implement phase.
  implement_max_turns: 80,
  # Conservative per-phase USD cost estimates. Used as a FALLBACK only — the
  # Claude adapter emits a :usage event with actual cost_usd when the CLI
  # reports total_cost_usd; the estimate is recorded when it does not.
  cost_estimates: %{
    specify: 0.20,
    clarify: 0.40,
    plan: 0.60,
    tasks: 0.30,
    analyze: 0.40,
    implement: 2.50,
    converge: 0.30
  },
  # Pinned Spec Kit CLI tag (drift diagnosis — plan §4.6).
  speckit_version: "v0.12.11"
