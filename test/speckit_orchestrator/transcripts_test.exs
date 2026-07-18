defmodule SpeckitOrchestrator.TranscriptsTest do
  # async: false — mutates the global :transcript_root app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{PhaseResult, Transcripts, Worktree}

  defp result,
    do: %PhaseResult{
      status: :ok,
      session_id: "s1",
      cost_usd: 0.1,
      tool_events: [],
      num_turns: 3,
      final_text: "plan written to specs/001/plan.md"
    }

  setup do
    root = Path.join(System.tmp_dir!(), "tr_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:speckit_orchestrator, :transcript_root, prev)
    end)

    %{root: root}
  end

  test "writes both the in-worktree copy and the durable copy", %{root: root} do
    wt_path = Path.join(System.tmp_dir!(), "wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(wt_path)
    on_exit(fn -> File.rm_rf(wt_path) end)

    wt = %Worktree{path: wt_path, branch: "feature/001-core-ledger", repo: ".", feature_id: "001"}

    assert {:ok, in_tree} = Transcripts.write(wt, 5, :plan, result())

    # in-worktree copy
    assert in_tree == Path.join([wt_path, ".speckit_logs", "05-plan.md"])
    assert File.read!(in_tree) =~ "plan written to specs/001/plan.md"

    # durable copy, keyed by feature id, outside the worktree
    durable = Path.join([root, "001", "05-plan.md"])
    assert File.exists?(durable)
    assert File.read!(durable) =~ "plan written to specs/001/plan.md"
  end

  test "durable write is best-effort and never breaks the in-worktree write" do
    wt_path = Path.join(System.tmp_dir!(), "wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(wt_path)
    on_exit(fn -> File.rm_rf(wt_path) end)

    # Point the durable root at an unwritable path; the worktree write still wins.
    Application.put_env(:speckit_orchestrator, :transcript_root, "/proc/nonexistent/deny")
    wt = %Worktree{path: wt_path, branch: "b", repo: ".", feature_id: "001"}

    assert {:ok, in_tree} = Transcripts.write(wt, 1, :specify, result())
    assert File.exists?(in_tree)
  end

  test "no worktree is a no-op" do
    assert Transcripts.write(nil, 1, :specify, result()) == :ok
  end
end
