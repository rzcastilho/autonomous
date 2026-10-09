defmodule Autonomous.CoordinatorProbeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Autonomous.CoordinatorProbe

  defmodule Stub do
    use GenServer

    def start_link(mode), do: GenServer.start_link(__MODULE__, mode)
    @impl true
    def init(mode), do: {:ok, mode}

    @impl true
    def handle_call(:status, _from, :answer = s), do: {:reply, %{finished?: false}, s}
    def handle_call(:status, _from, :stall = s), do: {:noreply, s}
    def handle_call(:status, _from, :crash = s), do: {:stop, :boom, s}
  end

  test "answers" do
    {:ok, pid} = Stub.start_link(:answer)
    assert {:ok, %{finished?: false}} = CoordinatorProbe.status(pid, 200)
  end

  test "timeout leaves caller alive" do
    {:ok, pid} = Stub.start_link(:stall)
    assert {:error, :timeout} = CoordinatorProbe.status(pid, 30)
    assert Process.alive?(pid)
  end

  test "unregistered name is :none" do
    assert :none = CoordinatorProbe.status(:no_such_coordinator_038, 30)
  end

  test "exit mid-call is :down" do
    {:ok, pid} = Stub.start_link(:crash)
    Process.flag(:trap_exit, true)
    capture_log(fn -> assert {:error, :down} = CoordinatorProbe.status(pid, 200) end)
  end

  test "dead pid is :none" do
    {:ok, pid} = Stub.start_link(:answer)
    GenServer.stop(pid)
    assert :none = CoordinatorProbe.status(pid, 30)
  end
end
