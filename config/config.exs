import Config

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
  # Per-phase model routing (full model strings — placeholders, verify in P2).
  models: %{
    specify: "claude-sonnet-4-6",
    clarify: "claude-opus-4-8",
    plan: "claude-opus-4-8",
    tasks: "claude-sonnet-4-6",
    analyze: "claude-opus-4-8",
    implement: "claude-sonnet-4-6",
    converge: "claude-sonnet-4-6"
  },
  # Ordered plan stack passed to the plan phase (documented placeholder).
  plan_stack: [],
  # Max features running concurrently (worktree-level parallelism).
  max_concurrency: 2,
  # Cost circuit-breaker budget for a run, in USD.
  budget_usd: 25.0,
  # Turn cap for the long-running implement phase.
  implement_max_turns: 80,
  # Pinned Spec Kit CLI tag (drift diagnosis — plan §4.6).
  speckit_version: "v0.12.11"
