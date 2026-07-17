import Config

# ---------------------------------------------------------------------------
# Runtime configuration — evaluated at boot (dev/prod), NOT at compile time.
#
# Everything here is driven by environment variables with sane defaults, so a
# run can be steered without editing code. Skipped under :test — the suite
# injects features directly and asserts the compile-time defaults, so env
# overrides must not leak into it.
# ---------------------------------------------------------------------------
if config_env() != :test do
  # "1" / "true" / "yes" / "on" (case-insensitive) → true; anything else → default.
  truthy = fn name, default ->
    case System.get_env(name) do
      nil -> default
      v -> String.downcase(v) in ~w(1 true yes on)
    end
  end

  # Target Spec Kit repo the orchestrator drives. `SPECKIT_REPO` wins; falls back
  # to the sibling LedgerLite validation target (docs/phase7-ledgerlite-runbook.md).
  repo =
    System.get_env("SPECKIT_REPO") ||
      "/Users/castilho/code/github.com/rzcastilho/ledgerlite"

  config :speckit_orchestrator,
    repo: repo,
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

  # Model pin: the ClaudeAgentSDK catalog accepts aliases (opus/sonnet); pin the
  # alias -> full-model mapping via these env vars for reproducibility (see
  # docs/harness-contract.md). Set them in the run environment, e.g.:
  #   ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
  #   ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
end
