import Config

# ---------------------------------------------------------------------------
# Runtime configuration — evaluated at boot, NOT at compile time.
#
# Everything here is driven by environment variables with sane defaults, so a
# run can be steered without editing code.
#
# Applied in every env EXCEPT :test. `:test` keeps the compile-time defaults
# (config/config.exs) so the deterministic suite can never be steered by a
# stray env var. This block used to be gated on `:prod` alone, which meant the
# startup path the runbook actually documents (`iex -S mix`, i.e. :dev) silently
# ignored every AUTONOMOUS_* var — including AUTONOMOUS_REPO, leaving the orchestrator
# pointed at its own repo (`repo: "."` from config.exs) with no backlog to run.
#
# AUTONOMOUS_REPO is REQUIRED in :prod (raises at boot, so a production run can
# never silently point at the wrong repo); elsewhere it is an optional override
# of the compile-time default.
# ---------------------------------------------------------------------------
if config_env() != :test do
  # Target Spec Kit repo the orchestrator drives.
  case config_env() do
    :prod ->
      config :autonomous, repo: System.fetch_env!("AUTONOMOUS_REPO")

    _ ->
      # Only override when set, so an unset var leaves config/config.exs's
      # default in place rather than pinning a second copy of it here.
      if repo = System.get_env("AUTONOMOUS_REPO") do
        config :autonomous, repo: repo
      end
  end

  # 019: every run is a stacked sequential run — AUTONOMOUS_PR_WORKFLOW and
  # AUTONOMOUS_MAX_CONCURRENCY named a run-shape decision that no longer exists.
  # Retired settings are refused, not silently ignored — set at all (any
  # value, including "false"/"0") aborts boot naming the retired setting
  # (contracts/run-start.md § Environment and stored configuration).
  if System.get_env("AUTONOMOUS_PR_WORKFLOW") do
    raise """
    AUTONOMOUS_PR_WORKFLOW is retired (019: every run is a stacked sequential \
    run — there is no other shape to toggle). Remove it from the environment.
    """
  end

  if System.get_env("AUTONOMOUS_MAX_CONCURRENCY") do
    raise """
    AUTONOMOUS_MAX_CONCURRENCY is retired (019: one feature runs at a time, \
    structurally — there is no concurrency setting). Remove it from the \
    environment.
    """
  end

  config :autonomous,
    # Root base branch for the first feature's PR (later features stack on the
    # prior branch).
    pr_base: System.get_env("AUTONOMOUS_PR_BASE") || "main",
    # Remote to push feature branches to and to preflight.
    pr_remote: System.get_env("AUTONOMOUS_PR_REMOTE") || "origin"

  if v = System.get_env("AUTONOMOUS_BUDGET_USD") do
    config :autonomous, budget_usd: elem(Float.parse(v), 0)
  end

  # Preferred stack handed to the plan phase. Unset/empty (the default) means
  # plan derives the stack from the target's constitution and manifest, which is
  # what you want for any target that already has one. Set it ONLY for a target
  # whose spec deliberately leaves the stack open, e.g.:
  #   AUTONOMOUS_PLAN_STACK="Python 3 (standard library only: argparse, unittest)"
  # A value contradicting the target makes plan refuse and ask a question no one
  # can answer headlessly — see the note in config/config.exs.
  case System.get_env("AUTONOMOUS_PLAN_STACK") do
    nil -> :ok
    "" -> :ok
    stack -> config :autonomous, plan_stack: [stack]
  end

  # Model pin: the ClaudeAgentSDK catalog accepts aliases (opus/sonnet); pin the
  # alias -> full-model mapping via these env vars for reproducibility (see
  # docs/harness-contract.md). Set them in the run environment, e.g.:
  #   ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
  #   ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
end
