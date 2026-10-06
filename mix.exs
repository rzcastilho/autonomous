defmodule Autonomous.MixProject do
  use Mix.Project

  def project do
    [
      app: :autonomous,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # 031: the release image runs `bin/autonomous start` with no build toolchain at
  # runtime. Node name and cookie come from rel/env.sh.eex (set by the entrypoint).
  defp releases do
    [
      autonomous: [
        include_executables_for: [:unix],
        applications: [autonomous: :permanent]
      ]
    ]
  end

  # test/support carries shared test helpers (e.g. FakeArtifacts, which makes the
  # offline fake SDKs write the files the artifact gate checks for).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {Autonomous.Application, []}
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
      # Fork of agentjido/jido_claude @ 51f8b6e plus one commit: `:settings` added to
      # the adapter's @option_keys so `--settings` reaches the CLI (feature 032
      # T029). Back to upstream once it carries the key.
      {:jido_claude,
       github: "rzcastilho/jido_claude", ref: "1b5d54a4222eab1e234d004133e67eca93120836"},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      # Control-plane console (008): Phoenix LiveView on Bandit. phoenix_pubsub
      # is already present transitively via jido_signal — promoted to a direct
      # dep since the console depends on it directly for ConsoleProjection.
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
