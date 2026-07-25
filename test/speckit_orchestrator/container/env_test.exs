defmodule SpeckitOrchestrator.Container.EnvTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Container.Env

  @required %{"SPECKIT_REPO" => "/home/alice/code/ledgerlite"}

  describe "SPECKIT_REPO" do
    test "required — absent raises naming the variable" do
      assert_raise ArgumentError, ~r/SPECKIT_REPO is not set/, fn -> Env.parse!(%{}) end
    end

    test "empty string is treated as absent" do
      assert_raise ArgumentError, ~r/SPECKIT_REPO is not set/, fn ->
        Env.parse!(%{"SPECKIT_REPO" => ""})
      end
    end

    test "present populates :repo" do
      assert Env.parse!(@required).repo == "/home/alice/code/ledgerlite"
    end
  end

  describe "path identity fields" do
    test "host_repo/host_home default to nil (non-container run)" do
      env = Env.parse!(@required)
      assert env.host_repo == nil
      assert env.host_home == nil
    end

    test "host_repo/host_home populate when present" do
      env =
        Env.parse!(
          Map.merge(@required, %{
            "AUTONOMOUS_HOST_REPO" => "/home/alice/code/ledgerlite",
            "AUTONOMOUS_HOST_HOME" => "/home/alice"
          })
        )

      assert env.host_repo == "/home/alice/code/ledgerlite"
      assert env.host_home == "/home/alice"
    end
  end

  describe "AUTONOMOUS_ROOT" do
    test "defaults to ~/.autonomous" do
      assert Env.parse!(@required).autonomous_root == "~/.autonomous"
    end

    test "absolute path accepted" do
      env = Env.parse!(Map.put(@required, "AUTONOMOUS_ROOT", "/data/autonomous"))
      assert env.autonomous_root == "/data/autonomous"
    end

    test "tilde path accepted" do
      env = Env.parse!(Map.put(@required, "AUTONOMOUS_ROOT", "~/custom"))
      assert env.autonomous_root == "~/custom"
    end

    test "relative path raises naming the variable and value" do
      assert_raise ArgumentError, ~r/AUTONOMOUS_ROOT must be an absolute path.*"relative\/path"/, fn ->
        Env.parse!(Map.put(@required, "AUTONOMOUS_ROOT", "relative/path"))
      end
    end
  end

  describe "SPECKIT_SPECS_ROOT" do
    test "defaults to specs/autonomous" do
      assert Env.parse!(@required).specs_root == "specs/autonomous"
    end

    test "relative path accepted" do
      env = Env.parse!(Map.put(@required, "SPECKIT_SPECS_ROOT", "specs/custom"))
      assert env.specs_root == "specs/custom"
    end

    test "absolute path raises naming the variable and value" do
      assert_raise ArgumentError, ~r/SPECKIT_SPECS_ROOT must be a relative path.*"\/abs"/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_SPECS_ROOT", "/abs"))
      end
    end
  end

  describe "numeric vars" do
    test "SPECKIT_MAX_CONCURRENCY defaults to 2" do
      assert Env.parse!(@required).max_concurrency == 2
    end

    test "SPECKIT_MAX_CONCURRENCY accepts a positive integer" do
      assert Env.parse!(Map.put(@required, "SPECKIT_MAX_CONCURRENCY", "5")).max_concurrency == 5
    end

    test "SPECKIT_MAX_CONCURRENCY non-numeric raises naming var + value" do
      assert_raise ArgumentError, ~r/SPECKIT_MAX_CONCURRENCY must be a positive integer.*"nope"/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_MAX_CONCURRENCY", "nope"))
      end
    end

    test "SPECKIT_MAX_CONCURRENCY zero raises" do
      assert_raise ArgumentError, ~r/SPECKIT_MAX_CONCURRENCY must be a positive integer.*"0"/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_MAX_CONCURRENCY", "0"))
      end
    end

    test "SPECKIT_BUDGET_USD defaults to 74.0" do
      assert Env.parse!(@required).budget_usd == 74.0
    end

    test "SPECKIT_BUDGET_USD accepts a positive float" do
      assert Env.parse!(Map.put(@required, "SPECKIT_BUDGET_USD", "10.5")).budget_usd == 10.5
    end

    test "SPECKIT_BUDGET_USD non-numeric raises naming var + value" do
      assert_raise ArgumentError, ~r/SPECKIT_BUDGET_USD must be a positive number.*"garbage"/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_BUDGET_USD", "garbage"))
      end
    end

    test "SPECKIT_IMPLEMENT_MAX_TURNS defaults to 80, raises on invalid" do
      assert Env.parse!(@required).implement_max_turns == 80

      assert_raise ArgumentError, ~r/SPECKIT_IMPLEMENT_MAX_TURNS must be a positive integer.*"-1"/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_IMPLEMENT_MAX_TURNS", "-1"))
      end
    end

    test "SPECKIT_PHASE_MAX_RETRIES defaults to 1, accepts zero, raises on negative" do
      assert Env.parse!(@required).phase_max_retries == 1
      assert Env.parse!(Map.put(@required, "SPECKIT_PHASE_MAX_RETRIES", "0")).phase_max_retries == 0

      assert_raise ArgumentError, ~r/SPECKIT_PHASE_MAX_RETRIES must be a non-negative integer.*"-2"/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_PHASE_MAX_RETRIES", "-2"))
      end
    end
  end

  describe "SPECKIT_PLAN_STACK" do
    test "unset/empty yields []" do
      assert Env.parse!(@required).plan_stack == []
      assert Env.parse!(Map.put(@required, "SPECKIT_PLAN_STACK", "")).plan_stack == []
    end

    test "a value yields a single-element list" do
      env = Env.parse!(Map.put(@required, "SPECKIT_PLAN_STACK", "Python 3 (stdlib only)"))
      assert env.plan_stack == ["Python 3 (stdlib only)"]
    end
  end

  describe "SPECKIT_MODEL_<PHASE>" do
    test "unset yields an empty map" do
      assert Env.parse!(@required).models == %{}
    end

    test "a known phase/alias populates the map" do
      env = Env.parse!(Map.put(@required, "SPECKIT_MODEL_CLARIFY", "opus"))
      assert env.models == %{clarify: "opus"}
    end

    test "unknown alias raises listing the accepted set" do
      assert_raise ArgumentError, ~r/not a known model alias.*accepted: \["opus", "sonnet"\]/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_MODEL_CLARIFY", "haiku"))
      end
    end

    test "unknown phase raises listing the known phases" do
      assert_raise ArgumentError, ~r/unknown phase.*known phases:/, fn ->
        Env.parse!(Map.put(@required, "SPECKIT_MODEL_BOGUS", "opus"))
      end
    end
  end

  describe "SPECKIT_PR_WORKFLOW" do
    test "defaults to false" do
      refute Env.parse!(@required).pr_workflow?
    end

    test "1/true/yes/on (any case) are truthy" do
      for v <- ~w(1 true yes on TRUE On) do
        assert Env.parse!(Map.put(@required, "SPECKIT_PR_WORKFLOW", v)).pr_workflow?
      end
    end

    test "anything else is false" do
      refute Env.parse!(Map.put(@required, "SPECKIT_PR_WORKFLOW", "nope")).pr_workflow?
    end
  end

  describe "AUTONOMOUS_CONSOLE_IP / PORT" do
    test "defaults" do
      env = Env.parse!(@required)
      assert env.console_ip == {0, 0, 0, 0}
      assert env.console_port == 4000
    end

    test "valid IPv4 and port accepted" do
      env =
        Env.parse!(
          Map.merge(@required, %{
            "AUTONOMOUS_CONSOLE_IP" => "127.0.0.1",
            "AUTONOMOUS_CONSOLE_PORT" => "4100"
          })
        )

      assert env.console_ip == {127, 0, 0, 1}
      assert env.console_port == 4100
    end

    test "invalid IP raises naming var + value" do
      assert_raise ArgumentError, ~r/AUTONOMOUS_CONSOLE_IP is not a valid IPv4 address.*"nope"/, fn ->
        Env.parse!(Map.put(@required, "AUTONOMOUS_CONSOLE_IP", "nope"))
      end
    end

    test "invalid port raises naming var + value" do
      assert_raise ArgumentError, ~r/AUTONOMOUS_CONSOLE_PORT must be a positive integer.*"port"/, fn ->
        Env.parse!(Map.put(@required, "AUTONOMOUS_CONSOLE_PORT", "port"))
      end
    end
  end

  describe "AUTONOMOUS_AUTOSTART" do
    test "unset yields :none" do
      assert Env.parse!(@required).autostart == :none
    end

    test "empty string yields :none" do
      assert Env.parse!(Map.put(@required, "AUTONOMOUS_AUTOSTART", "")).autostart == :none
    end

    test "\"ad-hoc\" yields :ad_hoc" do
      assert Env.parse!(Map.put(@required, "AUTONOMOUS_AUTOSTART", "ad-hoc")).autostart == :ad_hoc
    end

    test "a breakdown slug yields {:breakdown, slug}" do
      env = Env.parse!(Map.put(@required, "AUTONOMOUS_AUTOSTART", "003-recovery-reconciliation"))
      assert env.autostart == {:breakdown, "003-recovery-reconciliation"}
    end

    test "an unrecognised value raises" do
      assert_raise ArgumentError, ~r/AUTONOMOUS_AUTOSTART is neither empty/, fn ->
        Env.parse!(Map.put(@required, "AUTONOMOUS_AUTOSTART", "not a slug!"))
      end
    end
  end
end
