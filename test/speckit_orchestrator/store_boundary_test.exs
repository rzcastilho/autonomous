defmodule SpeckitOrchestrator.StoreBoundaryTest do
  @moduledoc """
  Grep guard (018, Constitution Principle I; contracts/store-api.md §
  Boundary rules): `Store.Mnesia` is the ONLY module that may reference
  `:mnesia` directly. Every pure core module — and every pure `Store.*`
  module (`Records`, `Ids`, `Capacity`, `Prune`, `Export`) — must never
  depend on it, so the pure decision surfaces stay testable with no schema
  and no running node.
  """

  use ExUnit.Case, async: true

  @lib_root Path.join([File.cwd!(), "lib", "speckit_orchestrator"])

  @pure_files [
    "feature.ex",
    "config.ex",
    "pipeline.ex",
    "ledger.ex",
    "release.ex",
    "backlog.ex",
    "severity.ex",
    "remediation.ex",
    "store/records.ex",
    "store/ids.ex",
    "store/capacity.ex",
    "store/prune.ex",
    "store/export.ex"
  ]

  @mnesia_reference ~r/(?<!:)\b:mnesia\b|Mnesia\./

  for file <- @pure_files do
    test "#{file} never references :mnesia" do
      path = Path.join(@lib_root, unquote(file))
      assert File.exists?(path), "expected #{path} to exist"

      contents = File.read!(path)

      refute Regex.match?(@mnesia_reference, contents),
             "#{unquote(file)} references :mnesia — pure core/store modules must stay Mnesia-free (Principle I)"
    end
  end

  test "Store.Mnesia is the only module under lib/ calling the real :mnesia API" do
    offenders =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "store/mnesia.ex"))
      |> Enum.filter(fn path ->
        # `:mnesia\.\w+\(` — an actual call, e.g. `:mnesia.create_table(`.
        # Doc-comment mentions (`` `:mnesia.create_table/2` ``, `/3` arity
        # references) use a slash, not a paren, and don't match.
        Regex.match?(~r/:mnesia\.\w+\(/, File.read!(path))
      end)

    assert offenders == [],
           "only store/mnesia.ex may call :mnesia.* directly, found real calls in: #{inspect(offenders)}"
  end
end
