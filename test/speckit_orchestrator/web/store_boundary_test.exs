defmodule SpeckitOrchestrator.Web.StoreBoundaryTest do
  @moduledoc """
  Grep guard (018, contracts/store-api.md § 5 Boundary rules, FR-030c,
  SC-007): no module under `lib/speckit_orchestrator/web/` references
  `:mnesia`, `Store.Query`, or `Store.Writer` — the console is an
  observability surface over the `SpeckitOrchestrator.*` facade only, never a
  second query path into the store. Nor does any web module read a durable
  state file from disk — the pre-018 manifest/checkpoint/transcript files
  this feature's clean break (FR-037) removed.
  """

  use ExUnit.Case, async: true

  @web_root Path.join([File.cwd!(), "lib", "speckit_orchestrator", "web"])

  @web_files @web_root
             |> Path.join("**/*.ex")
             |> Path.wildcard()

  @mnesia_reference ~r/(?<!:)\b:mnesia\b|Mnesia\./
  @store_query_or_writer ~r/Store\.(Query|Writer)\b/

  # The pre-018 second-copy artifacts FR-037 deleted: run.json (RunManifest),
  # checkpoint.json (Checkpoint), and the per-phase .speckit_logs/NN-*.md
  # files (Transcripts). A web module reading any of these would be reading a
  # copy of a fact the store already owns (SC-007).
  @state_file_reference ~r/checkpoint\.json|run\.json|\.speckit_logs/

  test "at least one file was found under lib/speckit_orchestrator/web/" do
    assert @web_files != [], "expected to find .ex files under #{@web_root}"
  end

  for file <- @web_files do
    relative = Path.relative_to(file, File.cwd!())

    test "#{relative} never references :mnesia" do
      contents = File.read!(unquote(file))

      refute Regex.match?(@mnesia_reference, contents),
             "#{unquote(relative)} references :mnesia — the console must call " <>
               "SpeckitOrchestrator.* facade functions only (FR-030c)"
    end

    test "#{relative} never references Store.Query or Store.Writer" do
      contents = File.read!(unquote(file))

      refute Regex.match?(@store_query_or_writer, contents),
             "#{unquote(relative)} references Store.Query/Store.Writer directly — " <>
               "the console must call SpeckitOrchestrator.* facade functions only (FR-030c)"
    end

    test "#{relative} never reads a pre-018 state file from disk" do
      contents = File.read!(unquote(file))

      refute Regex.match?(@state_file_reference, contents),
             "#{unquote(relative)} references a pre-018 state file (run.json/checkpoint.json/" <>
               ".speckit_logs) — that second copy of the store's facts no longer exists (FR-037, SC-007)"
    end
  end
end
