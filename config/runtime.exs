import Config

# ---------------------------------------------------------------------------
# Runtime configuration — evaluated at boot (dev/prod), NOT at compile time.
#
# Points the orchestrator at the target Spec Kit repo it drives. Phase 7 aims
# this at the prepared LedgerLite validation target; override for a real run.
#
# Skipped under :test — the suite injects features directly (see
# SpeckitOrchestrator.run/1 :features opt) and never resolves :repo, so leaving
# the compile-time default (".") avoids surprising the deterministic tests.
# ---------------------------------------------------------------------------
if config_env() != :test do
  # `SPECKIT_REPO` wins; falls back to the sibling LedgerLite target prepared in
  # Phase 7 (docs/phase7-ledgerlite-runbook.md).
  repo =
    System.get_env("SPECKIT_REPO") ||
      "/Users/castilho/code/github.com/rzcastilho/ledgerlite"

  config :speckit_orchestrator, repo: repo

  # Model pin: the ClaudeAgentSDK catalog accepts aliases (opus/sonnet); pin the
  # alias -> full-model mapping via these env vars for reproducibility (see
  # docs/harness-contract.md). Set them in the run environment, e.g.:
  #   ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
  #   ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
end
