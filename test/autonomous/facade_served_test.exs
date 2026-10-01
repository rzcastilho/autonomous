defmodule Autonomous.FacadeServedTest do
  # 031 FR-007: in a container the facade serves exactly one target. A call
  # naming another repository raises instead of reading or writing its store.
  # Container mode is injected per process (Instance.with_served/2), never by
  # flipping global config, so this stays hermetic and async-safe.
  use ExUnit.Case, async: true

  alias Autonomous.Instance
  alias Autonomous.Instance.NotServedError

  @served Instance.derive("/r/served", "o:served-aaaaaa", "/state")
  @foreign "/tmp/autonomous_facade_foreign_repo"

  defp foreign!(fun) do
    Instance.with_served(@served, fn ->
      error = assert_raise NotServedError, fun
      assert error.message =~ "this instance serves /r/served"
      assert error.message =~ "#{@foreign} is not served here"
    end)
  end

  describe "positional repository" do
    test "workers/1", do: foreign!(fn -> Autonomous.workers(@foreign) end)
    test "current_run_id/1", do: foreign!(fn -> Autonomous.current_run_id(@foreign) end)

    test "resumable/1 (partition string)" do
      Instance.with_served(@served, fn ->
        assert_raise NotServedError, fn -> Autonomous.resumable("o:other-bbbbbb") end
      end)
    end
  end

  describe ":repo option" do
    test "pending_questions/1", do: foreign!(fn -> Autonomous.pending_questions(repo: @foreign) end)

    test "answer/4",
      do: foreign!(fn -> Autonomous.answer("001", 1, %{}, repo: @foreign) end)

    test "continue_run/1", do: foreign!(fn -> Autonomous.continue_run(repo: @foreign) end)
    test "end_run/1", do: foreign!(fn -> Autonomous.end_run(repo: @foreign) end)
    test "resume/2", do: foreign!(fn -> Autonomous.resume("001", repo: @foreign) end)
    test "resume_run/1", do: foreign!(fn -> Autonomous.resume_run(repo: @foreign) end)
    test "run_history/1", do: foreign!(fn -> Autonomous.run_history(repo: @foreign) end)
    test "run_detail/2", do: foreign!(fn -> Autonomous.run_detail("r000001", repo: @foreign) end)

    test "export_run/3",
      do: foreign!(fn -> Autonomous.export_run("r000001", "/tmp/x.json", repo: @foreign) end)

    test "prune_preview/1", do: foreign!(fn -> Autonomous.prune_preview(repo: @foreign) end)
    test "prune/1", do: foreign!(fn -> Autonomous.prune(repo: @foreign) end)

    test "record_pr/3",
      do: foreign!(fn -> Autonomous.record_pr("001", "https://example.test/pr/1", repo: @foreign) end)

    test "resolve/2 (parked-run lookup)", do: foreign!(fn -> Autonomous.resolve("001", repo: @foreign) end)

    test "run_spec/2 (taken-id gathering)",
      do: foreign!(fn -> Autonomous.run_spec("add a thing", repo: @foreign) end)

    test "preview_single_spec/2",
      do: foreign!(fn -> Autonomous.preview_single_spec("add a thing", repo: @foreign) end)
  end

  test "outside container mode the same calls are not refused by the guard" do
    # No injected identity and require_container: false => Instance is a no-op.
    assert :ok = Instance.assert_served!(@foreign)
  end

  test "the :repo option is read in exactly one place (served_repo/1)" do
    source = File.read!("lib/autonomous.ex")
    reads = Regex.scan(~r/Keyword\.get\(opts, :repo/, source)

    assert length(reads) == 1,
           "every :repo read must go through served_repo/1; found #{length(reads)} direct reads"

    assert source =~ ~r/defp served_repo\(opts\) do\s+repo = Keyword\.get\(opts, :repo, Config\.repo\(\)\)/
  end
end
