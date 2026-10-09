defmodule Autonomous.ConsoleProjectionResilienceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Autonomous.ConsoleProjection

  defmodule StubCoordinator do
    @moduledoc false
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :stall, name: name)
    def release(pid), do: GenServer.call(pid, :release)

    @impl true
    def init(mode), do: {:ok, %{mode: mode, held: []}}

    @impl true
    def handle_call(:status, from, %{mode: :stall} = s),
      do: {:noreply, %{s | held: [from | s.held]}}

    def handle_call(:status, _from, s), do: {:reply, %{finished?: false, marker: :fresh}, s}

    def handle_call(:release, _from, s) do
      Enum.each(s.held, &GenServer.reply(&1, %{finished?: false, marker: :fresh}))
      {:reply, :ok, %{s | mode: :answer, held: []}}
    end
  end

  setup do
    name = :"stub_coord_#{System.unique_integer([:positive])}"
    stub = start_supervised!(%{id: name, start: {StubCoordinator, :start_link, [name]}})
    Phoenix.PubSub.subscribe(Autonomous.PubSub, ConsoleProjection.topic())
    %{coord: name, stub: stub}
  end

  defp start_projection(coord) do
    start_supervised!(
      {ConsoleProjection,
       name: :"proj_#{System.unique_integer([:positive])}",
       coordinator: coord,
       reconcile_ms: 20,
       probe_timeout: 50}
    )
  end

  defp phase_event(pid, id, phase) do
    send(
      pid,
      {:telemetry_event, [:speckit, :phase, :start], %{system_time: 0},
       %{feature_id: id, phase: phase}}
    )
  end

  test "stalled coordinator never kills the projection or its feed", %{coord: coord, stub: stub} do
    log =
      capture_log(fn ->
        pid = start_projection(coord)
        ref = Process.monitor(pid)

        for phase <- [:specify, :clarify, :plan], do: phase_event(pid, "038", phase)
        %{feed: feed} = ConsoleProjection.read(pid)
        assert length(feed) == 3

        # several probe timeouts elapse
        Process.sleep(250)
        refute_received {:DOWN, ^ref, _, _, _}

        # read answers immediately mid-stall
        {micros, %{feed: kept}} = :timer.tc(fn -> ConsoleProjection.read(pid) end)
        assert length(kept) == 3
        assert micros < 500_000

        phase_event(pid, "038", :tasks)
        assert length(ConsoleProjection.read(pid).feed) == 4
        assert Process.alive?(pid)

        # Only this projection's reconciles (the stub's marker) — the app's own
        # projection broadcasts `coordinator: nil` reconciles on the same topic.
        refute_received {:console, :reconciled, %{coordinator: %{marker: _}, delayed?: false}}

        StubCoordinator.release(stub)
        assert_receive {:console, :reconciled, %{coordinator: %{marker: :fresh}}}, 1_000

        assert ConsoleProjection.last_known(pid).coordinator == %{
                 finished?: false,
                 marker: :fresh
               }

        assert Process.alive?(pid)
      end)

    refute log =~ "terminating"
  end

  describe "history rebuild (US2)" do
    defp detail do
      t = ~U[2026-10-09 10:00:00Z]

      %{
        run: %{key: {"repo", "r1"}, started_at: t},
        cost_entries: [],
        features: [
          %{
            feature_id: "001",
            status: :done,
            terminal_reason: nil,
            pr_url: "https://example.test/pr/1",
            ended_at: DateTime.add(t, 60),
            phase_attempts: [
              %{
                phase: :specify,
                attempt_id: "a1",
                started_at: DateTime.add(t, 1),
                ended_at: DateTime.add(t, 30),
                outcome: :ok
              }
            ]
          }
        ]
      }
    end

    defp start_with(history, coord) do
      start_supervised!(
        {ConsoleProjection,
         name: :"proj_#{System.unique_integer([:positive])}",
         coordinator: coord,
         reconcile_ms: 0,
         history: history}
      )
    end

    test "feed and slices are rebuilt from the loader on start", %{coord: coord} do
      pid = start_with(fn -> {:ok, detail()} end, coord)
      model = ConsoleProjection.read(pid)

      assert Enum.map(model.feed, & &1.text) |> Enum.reverse() == [
               "run started",
               "phase specify started",
               "phase specify -> :ok",
               "feature terminal done (nil)",
               "PR opened: https://example.test/pr/1"
             ]

      assert Map.has_key?(model.features, "001")
    end

    test "a live event equal to a rebuilt entry appears once", %{coord: coord} do
      pid = start_with(fn -> {:ok, detail()} end, coord)
      before = ConsoleProjection.read(pid)

      send(
        pid,
        {:telemetry_event, [:speckit, :phase, :start], %{}, %{feature_id: "001", phase: :specify}}
      )

      assert ConsoleProjection.read(pid).feed == before.feed
    end

    test ":none loader yields an empty model", %{coord: coord} do
      pid = start_with(fn -> :none end, coord)
      assert ConsoleProjection.read(pid).feed == []
    end

    test "failing loader logs one warning and still starts", %{coord: coord} do
      log =
        capture_log(fn ->
          pid = start_with(fn -> raise "boom" end, coord)
          assert ConsoleProjection.read(pid).feed == []
        end)

      assert log =~ "console history rebuild raised"
    end

    test "restart after kill rebuilds the feed", %{coord: coord} do
      name = :"proj_restart_#{System.unique_integer([:positive])}"

      start_supervised!(
        {ConsoleProjection,
         name: name, coordinator: coord, reconcile_ms: 0, history: fn -> {:ok, detail()} end}
      )

      old = Process.whereis(name)
      Process.exit(old, :kill)
      Process.sleep(50)
      new = Process.whereis(name)
      assert new && new != old
      assert length(ConsoleProjection.read(name).feed) == 5
    end
  end

  describe "delayed notice (US3)" do
    test "two misses broadcast delayed, success clears it, warnings are rate limited",
         %{coord: coord, stub: stub} do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :info], fn ->
          pid = start_projection(coord)

          assert_receive {:console, :reconciled, %{delayed?: true}}, 1_000
          assert ConsoleProjection.last_known(pid).delayed?

          Process.sleep(300)
          StubCoordinator.release(stub)
          assert_receive {:console, :reconciled, %{delayed?: false}}, 1_000
          Process.sleep(50)
          refute ConsoleProjection.last_known(pid).delayed?
        end)

      assert length(Regex.scan(~r/not answering/, log)) == 1
      assert log =~ "answering again"
      refute log =~ "[error]"
    end
  end
end
