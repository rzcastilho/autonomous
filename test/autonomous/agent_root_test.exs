defmodule Autonomous.AgentRootTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Autonomous.{AgentRoot, Feature, PhaseResult, Prompts}

  describe "advertised?/1" do
    test "true only when both markers are \"1\"" do
      assert AgentRoot.advertised?(%{
               "AUTONOMOUS_CONTAINER" => "1",
               "AUTONOMOUS_AGENT_ROOT" => "1"
             })

      refute AgentRoot.advertised?(%{"AUTONOMOUS_CONTAINER" => "1"})
      refute AgentRoot.advertised?(%{"AUTONOMOUS_AGENT_ROOT" => "1"})

      refute AgentRoot.advertised?(%{
               "AUTONOMOUS_CONTAINER" => "1",
               "AUTONOMOUS_AGENT_ROOT" => "0"
             })

      refute AgentRoot.advertised?(%{})
    end
  end

  describe "session_env/1 and prompt_note/1" do
    test "off is empty" do
      assert AgentRoot.session_env(false) == %{}
      assert AgentRoot.prompt_note(false) == ""
    end

    test "on carries both markers and the versioned note" do
      assert AgentRoot.session_env(true) ==
               %{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_AGENT_ROOT" => "1"}

      note = AgentRoot.prompt_note(true)
      assert String.starts_with?(note, "\n\n")
      assert note == "\n\n" <> Prompts.load("agent_root")
    end
  end

  defp bash(id, cmd),
    do: %{
      kind: :call,
      payload: %{"name" => "Bash", "call_id" => id, "input" => %{"command" => cmd}}
    }

  defp result(id, out), do: %{kind: :result, payload: %{"call_id" => id, "output" => out}}

  defp result_with(events), do: %PhaseResult{tool_events: events}

  describe "installs/1" do
    test "single install" do
      r = result_with([bash("1", "sudo apt-get install -y libfoo-dev"), result("1", "ok")])

      assert [%{packages: ["libfoo-dev"], command: "sudo apt-get install -y libfoo-dev"}] =
               AgentRoot.installs(r)
    end

    test "chained update && install, options are not packages" do
      r =
        result_with([
          bash(
            "1",
            "sudo apt-get update && sudo -n apt-get install -y --no-install-recommends libasound2-dev pkg-config"
          )
        ])

      assert [%{packages: ["libasound2-dev", "pkg-config"]}] = AgentRoot.installs(r)
    end

    test "env-assignment prefix and apt are recognised" do
      r = result_with([bash("1", "sudo DEBIAN_FRONTEND=noninteractive apt install -y zz-dev")])
      assert [%{packages: ["zz-dev"]}] = AgentRoot.installs(r)
    end

    test "a denied call is skipped" do
      r =
        result_with([
          bash("1", "sudo apt-get install -y libfoo-dev"),
          result("1", "scope_guard[strict|orchestrated]: bash_sudo: sudo")
        ])

      assert AgentRoot.installs(r) == []
    end

    test "non-install sudo, no sudo, nil" do
      assert AgentRoot.installs(result_with([bash("1", "sudo dpkg -s libfoo")])) == []
      assert AgentRoot.installs(result_with([bash("1", "apt-get install foo")])) == []
      assert AgentRoot.installs(result_with([])) == []
      assert AgentRoot.installs(nil) == []
    end
  end

  describe "log_installs/3" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "one line per install with the exact format" do
      feature = %Feature{id: "003", number: 3, slug: "x", path: "/p", spec_number: 3}

      r =
        result_with([
          bash("1", "sudo apt-get update && sudo apt-get install -y libasound2-dev pkg-config"),
          bash("2", "sudo apt-get install -y other-dev")
        ])

      log = capture_log(fn -> assert :ok = AgentRoot.log_installs(feature, :implement, r) end)

      assert log =~
               "agent root: feature 003 (implement) installed system packages: libasound2-dev pkg-config — add them to `scripts/autonomous build --apt` to persist"

      assert log =~ "installed system packages: other-dev"
    end

    test "nothing when there is no install" do
      feature = %Feature{id: "003", number: 3, slug: "x", path: "/p"}
      assert capture_log(fn -> AgentRoot.log_installs(feature, :plan, result_with([])) end) == ""
    end
  end
end
