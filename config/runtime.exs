import Config

# ---------------------------------------------------------------------------
# Runtime configuration — evaluated at boot (dev/prod), NOT at compile time.
#
# Everything here is driven by environment variables with sane defaults, so a
# run can be steered without editing code. Applied only in :prod — dev/test keep
# the compile-time defaults (config/config.exs), so the deterministic suite and
# local iex sessions are never steered by a stray env var. In :prod, SPECKIT_REPO
# MUST be set explicitly (no fallback).
# ---------------------------------------------------------------------------
if config_env() == :prod do
  # Single configuration surface (FR-020): SpeckitOrchestrator.Container.Env
  # parses and validates the whole boot environment, raising loudly (naming
  # the variable, and the value for numeric/enum fields) on anything required-
  # but-absent or present-but-invalid — see
  # specs/015-container-isolation/contracts/environment.md.
  env = SpeckitOrchestrator.Container.Env.load!()

  config :speckit_orchestrator,
    repo: env.repo,
    # Stacked sequential PR workflow (docs/runbook.md → "Stacked sequential PR
    # workflow"). SPECKIT_PR_WORKFLOW=true forces cap 1, preflights the remote,
    # and opens a stacked PR per feature on :done.
    pr_workflow: env.pr_workflow?,
    # Root base branch for the first feature's PR (later features stack on the
    # prior branch).
    pr_base: env.pr_base,
    # Remote to push feature branches to and to preflight.
    pr_remote: env.pr_remote,
    max_concurrency: env.max_concurrency,
    budget_usd: env.budget_usd,
    implement_max_turns: env.implement_max_turns,
    phase_max_retries: env.phase_max_retries,
    # Machine-global base for worktrees + durable transcripts + the preflight
    # report (FR-023) — must resolve onto the durable run-state mount.
    autonomous_root: env.autonomous_root,
    # In-repo root for committed breakdown/ad-hoc feature files.
    specs_root: env.specs_root,
    # Pinned Spec Kit CLI tag — drift diagnosis (tool_specify preflight check).
    speckit_version: env.speckit_version

  # Preferred stack handed to the plan phase. Unset/empty (the default) means
  # plan derives the stack from the target's constitution and manifest, which is
  # what you want for any target that already has one. Set it ONLY for a target
  # whose spec deliberately leaves the stack open, e.g.:
  #   SPECKIT_PLAN_STACK="Python 3 (standard library only: argparse, unittest)"
  # A value contradicting the target makes plan refuse and ask a question no one
  # can answer headlessly — see the note in config/config.exs.
  if env.plan_stack != [] do
    config :speckit_orchestrator, plan_stack: env.plan_stack
  end

  # Per-phase model routing. Values are CLI aliases (opus/sonnet) — the pinned
  # ClaudeAgentSDK catalog rejects full model strings; pin reproducibility via
  # ANTHROPIC_DEFAULT_*_MODEL (forwarded to the CLI unchanged, see
  # docs/harness-contract.md). Only overrides the phases actually set,
  # layering onto config.exs's compile-time defaults.
  if map_size(env.models) > 0 do
    config :speckit_orchestrator,
      models: Map.merge(SpeckitOrchestrator.Config.models(), env.models)
  end

  # `mix phx.server` doesn't exist in a release — `server: true` is what opens
  # the TCP listener. Bind inside the container is 0.0.0.0 by default (a
  # loopback bind inside a network namespace is unreachable from the host);
  # host exposure is the launcher's `-p 127.0.0.1:<port>:<port>` (FR-024).
  # check_origin matches both spellings at the SAME configured port so the
  # LiveView socket isn't silently rejected regardless of which the operator
  # opens (research.md §R12).
  config :speckit_orchestrator, SpeckitOrchestrator.Web.Endpoint,
    server: true,
    http: [ip: env.console_ip, port: env.console_port],
    check_origin: [
      "http://localhost:#{env.console_port}",
      "http://127.0.0.1:#{env.console_port}"
    ]
end
