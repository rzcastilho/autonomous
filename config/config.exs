import Config

# Keep test output readable — the runner logs a line per phase transition.
if config_env() == :test do
  config :logger, level: :warning

  # Durable transcripts default to a repo-relative sibling dir; in tests pin them
  # to a tmp path so runs that drive FeatureRunner/Transcripts don't write into
  # the real ../.speckit-transcripts. `autonomous_root` (012) is the
  # machine-global base for the new Layout-resolved worktree/transcript roots —
  # pin it too, or every facade-preflight test would create real dirs under the
  # developer's actual `~/.autonomous`.
  config :speckit_orchestrator,
    transcript_root: Path.join(System.tmp_dir!(), "speckit_test_transcripts"),
    autonomous_root: Path.join(System.tmp_dir!(), "speckit_test_autonomous")
end

# ---------------------------------------------------------------------------
# Control-plane console (008) — Phoenix LiveView on Bandit, loopback bind, no
# auth pipeline (FR-035). `mix phx.server` is the only thing that actually
# opens the TCP listener (it sets Application.put_env(:phoenix, :serve_endpoints,
# true)); plain `mix test`/`iex -S mix` boot the endpoint's config process
# without binding a port, so the console never competes for 4000 during the
# hermetic test suite.
# ---------------------------------------------------------------------------
config :speckit_orchestrator, SpeckitOrchestrator.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "d95b33a1423f921b332c4b90b63972ea850e12e0a70ad8a467c73d6b59453320d95b33a",
  live_view: [signing_salt: "sO2z3sYqCPqm9k1r"],
  pubsub_server: SpeckitOrchestrator.PubSub,
  render_errors: [formats: [html: SpeckitOrchestrator.Web.ErrorHTML], layout: false],
  # quickstart.md tells the operator to open http://127.0.0.1:<port>/, but
  # `url: [host: "localhost"]` alone makes Phoenix's default check_origin
  # reject the LiveView socket's Origin header on that host — the page loads
  # (dead render) but every phx-click/phx-submit is silently inert (no error
  # banner). Both loopback spellings are the same trusted single-operator
  # console (FR-035), so both are allowed explicitly.
  check_origin: ["http://localhost:4000", "http://127.0.0.1:4000"]

config :phoenix, :json_library, Jason

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
    converge: "sonnet",
    describe: "sonnet"
  },
  # Ordered plan stack passed to the plan phase. EMPTY BY DEFAULT: plan then
  # derives the stack from the target's own constitution and manifest
  # (mix.exs/package.json/…). Set it only for a target that genuinely cannot be
  # derived — e.g. the LedgerLite spec deliberately delegates language/format to
  # plan, so that run sets SPECKIT_PLAN_STACK="Python 3 (standard library only:
  # argparse, unittest; no third-party dependencies)".
  #
  # A stack that contradicts the target (the old hardcoded Python default against
  # an Elixir/Phoenix target) makes plan REFUSE and ask which to use — an
  # unanswerable question in a headless run, so plan writes no plan.md and every
  # later phase silently no-ops. See config/runtime.exs → SPECKIT_PLAN_STACK.
  plan_stack: [],
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
  # Consecutive no-progress attempts on one task-phase before it is judged
  # stuck (FR-013). Feature 015 — implement phase chunking.
  implement_no_progress_limit: 2,
  # Session-ceiling formula (FR-013a): per_task_phase * task_phase_count +
  # headroom, frozen at implement-step start. Feature 015.
  implement_sessions_per_task_phase: 2,
  implement_sessions_headroom: 4,
  # Analyze auto-remediation loop (feature 017) — on by default. A bounded
  # pre-gate corrective step runs against at-or-above-threshold findings
  # before the analyze gate decides. See Remediation.Settings.validate/1 for
  # the single validation point (FR-011); these are only defaults.
  auto_remediation: true,
  auto_remediation_threshold: :high,
  auto_remediation_attempt_limit: 2,
  auto_remediation_model: nil,
  # Exhaustion policy (feature 021) — read only when the attempt limit above is
  # reached with residual findings still at or above the threshold. Default
  # :escalate reproduces today's behaviour byte-for-byte; :proceed lets the
  # gate advance instead. See Remediation.Settings.validate/1 for the single
  # validation point (FR-010); this is only the default.
  auto_remediation_exhaustion_policy: :escalate,
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
    converge: 0.95,
    describe: 0.15,
    # NEW (feature 017) — runs on the analyze model (FR-009b, SC-008).
    auto_remediation: 1.26,
    # NEW (feature 017) — closes a pre-existing 0.0 hole: 013's operator
    # pre-phase remediation step had no estimate at all (research R6).
    remediation: 0.95
  },
  # Pinned Spec Kit CLI tag (drift diagnosis — plan §4.6).
  speckit_version: "v0.12.11"
