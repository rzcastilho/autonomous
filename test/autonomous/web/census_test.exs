defmodule Autonomous.Web.CensusTest do
  @moduledoc """
  Opt-in, machine-local re-measure of feature 042 over real saved conversations
  (`AUTONOMOUS_CENSUS_DIR`). Excluded by default; see quickstart §3.
  """
  use ExUnit.Case, async: true

  alias Autonomous.ConversationFile
  alias Autonomous.Web.{ConversationClass, ConversationRows, SessionStatus}

  @moduletag :census

  defp files do
    case System.get_env("AUTONOMOUS_CENSUS_DIR") do
      nil -> []
      dir -> dir |> Path.expand() |> Path.join("**/*.jsonl") |> Path.wildcard()
    end
  end

  defp load(path) do
    case ConversationFile.page(path, 0, 10_000_000) do
      {:ok, entries, _} -> entries
      _ -> []
    end
  end

  test "default blocks are at most 35% of entries; nothing is silently dropped" do
    all = files() |> Enum.map(&load/1) |> Enum.reject(&(&1 == []))
    assert all != [], "set AUTONOMOUS_CENSUS_DIR to a directory of conversation files"

    {entries, blocks} =
      Enum.reduce(all, {0, 0}, fn es, {e, b} ->
        {rows, _} = ConversationRows.rows(es)
        {e + length(es), b + length(rows)}
      end)

    assert blocks / entries <= 0.35

    for es <- all, e <- es do
      c = ConversationClass.classify(e)

      if e.kind in [:prompt, :assistant_text, :thinking, :tool_call, :tool_result] do
        assert ConversationClass.visible?(c, false), "#{e.kind} must be visible"
      end

      assert ConversationClass.visible?(c, false) or c.placement in [:signal, :header_signal]
    end
  end

  test "live fold equals saved fold for every file" do
    for path <- files() do
      entries = load(path)
      incremental = Enum.reduce(entries, SessionStatus.new(), &SessionStatus.apply(&2, &1))
      assert incremental == SessionStatus.apply_all(SessionStatus.new(), entries)

      case ConversationFile.fold(path, SessionStatus.new(), &SessionStatus.apply(&2, &1)) do
        {:ok, folded} -> assert folded == incremental
        _ -> :ok
      end
    end
  end
end
