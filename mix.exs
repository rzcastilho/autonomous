defmodule SpeckitOrchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :speckit_orchestrator,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # test/support carries shared test helpers (e.g. FakeArtifacts, which makes the
  # offline fake SDKs write the files the artifact gate checks for).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SpeckitOrchestrator.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  #
  # Harness data-plane deps (jido_harness, jido_claude) are NOT on Hex as of
  # 2026-07 — pinned to GitHub HEAD SHAs captured during Phase 0 dep probe.
  # Bump deliberately; re-check Hex monthly (plan §2). If they fail to resolve
  # or block `mix compile`, they may be commented out — Phase 1 (pure core) has
  # zero dependency on them. See docs/harness-contract.md.
  defp deps do
    [
      {:jido, "~> 2.2"},
      {:jido_harness,
       github: "agentjido/jido_harness",
       ref: "ae3751d7d0464a3097cb119ffbac98ccbedf607c",
       override: true},
      {:jido_claude,
       github: "agentjido/jido_claude", ref: "51f8b6e30cbf3839533d307399e12a136baf734f"},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
