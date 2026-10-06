defmodule Autonomous.Integration.BackgroundWaitTest do
  @moduledoc """
  LIVE, opt-in probes for feature 032 (`specs/032-headless-background-wait`,
  quickstart.md §2). Each drives the **real** `claude` CLI (pinned 2.1.287),
  so each is `@tag :integration` — excluded by default and run only with:

      mise exec -- mix test test/autonomous/integration/background_wait_test.exs \\
        --include integration

  Re-run after every CLI bump: the marker wording lives in
  `Autonomous.BackgroundMarker`, and this is what notices a reword.
  """

  # async: false — drives a real CLI.
  use ExUnit.Case, async: false

  alias Autonomous.{Feature, PhaseRequest, PhaseResult, PhaseSession}
  alias Jido.Harness.RunRequest

  @moduletag :integration

  defp tmp_repo do
    root = Path.join(System.tmp_dir!(), "bgwait_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q"], cd: root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp run_live(request, deadline_ms) do
    {:ok, stream} = Jido.Harness.run_request(:claude, request, [])
    PhaseSession.reduce(stream, deadline_ms)
  end

  # Probe 2 (quickstart §2): the live wording still parses. The model is told to
  # background a short command and stop; the fold must see exactly one stranded
  # command.
  test "a command the model backgrounds explicitly is detected as stranded" do
    request =
      RunRequest.new!(%{
        prompt:
          "Use the Bash tool exactly once, with run_in_background set to true, to run " <>
            "`sleep 5`. Then end your turn immediately without reading any output.",
        cwd: tmp_repo(),
        model: "haiku",
        max_turns: 4,
        permission_mode: :accept_edits,
        allowed_tools: ["Bash"],
        disallowed_tools: ~w(Agent Task ScheduleWakeup Monitor)
      })

    result = run_live(request, 180_000)

    assert result.status == :ok
    assert [command] = PhaseResult.stranded_background(result)
    assert command =~ "sleep 5"
  end

  # Probe 1 (quickstart §2): the orchestrator's `--settings`/env timeouts beat a
  # target's own `.claude/settings.json` `env`. The target pins 60 s; a session
  # built with a 50-min deadline must still see 2_700_000.
  test "orchestrator BASH_MAX_TIMEOUT_MS wins over the target's project settings" do
    cwd = tmp_repo()
    File.mkdir_p!(Path.join(cwd, ".claude"))

    File.write!(
      Path.join([cwd, ".claude", "settings.json"]),
      Jason.encode!(%{"env" => %{"BASH_MAX_TIMEOUT_MS" => "60000"}})
    )

    feature = %Feature{id: "001", number: 1, slug: "probe", path: "docs/breakdown/001-probe.md"}

    request =
      feature
      |> PhaseRequest.build(:specify, cwd: cwd, deadline_ms: 3_000_000)
      |> Map.merge(%{
        prompt:
          "Use the Bash tool once to run `echo VALUE=$BASH_MAX_TIMEOUT_MS`, then reply with " <>
            "only the output line.",
        model: "haiku",
        max_turns: 4,
        allowed_tools: ["Bash"]
      })

    result = run_live(request, 180_000)

    assert result.status == :ok
    assert result.final_text =~ "VALUE=2700000"
  end
end
