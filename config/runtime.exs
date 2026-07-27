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
# ignored every SPECKIT_* var — including SPECKIT_REPO, leaving the orchestrator
# pointed at its own repo (`repo: "."` from config.exs) with no backlog to run.
#
# SPECKIT_REPO is REQUIRED in :prod (raises at boot, so a production run can
# never silently point at the wrong repo); elsewhere it is an optional override
# of the compile-time default.
# ---------------------------------------------------------------------------
if config_env() != :test do
  # "1" / "true" / "yes" / "on" (case-insensitive) → true; anything else →
  # default. Trimmed, so an exported value carrying stray whitespace (common
  # with `export FOO="true "` or a value pasted from a .env file) still reads
  # as true instead of silently falling back to the default.
  truthy = fn name, default ->
    case System.get_env(name) do
      nil -> default
      v -> v |> String.trim() |> String.downcase() |> Kernel.in(~w(1 true yes on))
    end
  end

  # Target Spec Kit repo the orchestrator drives.
  case config_env() do
    :prod ->
      config :speckit_orchestrator, repo: System.fetch_env!("SPECKIT_REPO")

    _ ->
      # Only override when set, so an unset var leaves config/config.exs's
      # default in place rather than pinning a second copy of it here.
      if repo = System.get_env("SPECKIT_REPO") do
        config :speckit_orchestrator, repo: repo
      end
  end

  config :speckit_orchestrator,
    # Stacked sequential PR workflow (docs/runbook.md → "Stacked sequential PR
    # workflow"). SPECKIT_PR_WORKFLOW=true forces cap 1, preflights the remote,
    # and opens a stacked PR per feature on :done.
    pr_workflow: truthy.("SPECKIT_PR_WORKFLOW", false),
    # Root base branch for the first feature's PR (later features stack on the
    # prior branch).
    pr_base: System.get_env("SPECKIT_PR_BASE") || "main",
    # Remote to push feature branches to and to preflight.
    pr_remote: System.get_env("SPECKIT_PR_REMOTE") || "origin"

  # Optional numeric overrides — only applied when the env var is set, so the
  # compile-time defaults (config/config.exs) stand otherwise.
  if v = System.get_env("SPECKIT_MAX_CONCURRENCY") do
    config :speckit_orchestrator, max_concurrency: String.to_integer(v)
  end

  if v = System.get_env("SPECKIT_BUDGET_USD") do
    config :speckit_orchestrator, budget_usd: elem(Float.parse(v), 0)
  end

  # Preferred stack handed to the plan phase. Unset/empty (the default) means
  # plan derives the stack from the target's constitution and manifest, which is
  # what you want for any target that already has one. Set it ONLY for a target
  # whose spec deliberately leaves the stack open, e.g.:
  #   SPECKIT_PLAN_STACK="Python 3 (standard library only: argparse, unittest)"
  # A value contradicting the target makes plan refuse and ask a question no one
  # can answer headlessly — see the note in config/config.exs.
  case System.get_env("SPECKIT_PLAN_STACK") do
    nil -> :ok
    "" -> :ok
    stack -> config :speckit_orchestrator, plan_stack: [stack]
  end

  # Model pin: the ClaudeAgentSDK catalog accepts aliases (opus/sonnet); pin the
  # alias -> full-model mapping via these env vars for reproducibility (see
  # docs/harness-contract.md). Set them in the run environment, e.g.:
  #   ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
  #   ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
end
