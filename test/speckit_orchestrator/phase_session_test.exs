defmodule SpeckitOrchestrator.PhaseSessionTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Event
  alias SpeckitOrchestrator.{PhaseResult, PhaseSession}

  defp ev(type, payload, session_id \\ nil) do
    Event.new!(%{type: type, provider: :claude, session_id: session_id, payload: payload})
  end

  defp completed_events do
    [
      ev(:session_started, %{}, "sess-1"),
      ev(:output_text_delta, %{"text" => "hello"}),
      ev(
        :session_completed,
        %{"result" => "hello", "num_turns" => 1, "is_error" => false},
        "sess-1"
      )
    ]
  end

  # Stand-in for the SDK's transport GenServer: linked to the process that
  # starts the stream (as `CoreTransport.start_link` is), reports to the test
  # when `terminate/2` runs — the hook the real transport uses to kill the CLI.
  defmodule FakeTransport do
    use GenServer

    def start_link(notify), do: GenServer.start_link(__MODULE__, notify)

    @impl true
    def init(notify), do: {:ok, notify}

    @impl true
    def terminate(reason, notify) do
      send(notify, {:transport_terminated, self(), reason})
      :ok
    end
  end

  # A stream that emits `head` and then behaves like the SDK's `receive_next`
  # on a quiet session: polls, never emits, and halts only once its transport
  # is gone. `notify` receives the transport pid.
  defp stuck_stream(head, notify) do
    Stream.resource(
      fn ->
        {:ok, transport} = FakeTransport.start_link(notify)
        send(notify, {:transport_started, transport})
        {head, transport}
      end,
      fn
        {[event | rest], transport} -> {[event], {rest, transport}}
        {[], transport} = state -> poll(state, transport)
      end,
      fn _ -> :ok end
    )
  end

  defp poll(state, transport) do
    receive do
    after
      20 -> if Process.alive?(transport), do: {[], state}, else: {:halt, state}
    end
  end

  test "a stream that ends in time folds exactly as PhaseResult.reduce/1" do
    assert PhaseSession.reduce(completed_events(), 5_000) ==
             PhaseResult.reduce(completed_events())
  end

  test "call_timeout/1 is strictly larger than the deadline it wraps" do
    assert PhaseSession.call_timeout(1_000) > 1_000
    assert PhaseSession.call_timeout(:timer.minutes(90)) > :timer.minutes(90)
  end

  test "a session past its deadline is cut: transport terminated, partial fold kept, classified exhausted" do
    stream = stuck_stream([ev(:session_started, %{}, "sess-cut")], self())

    result = PhaseSession.reduce(stream, 150)

    assert_received {:transport_started, transport}
    # The transport was stopped through GenServer.stop — terminate/2 ran (the
    # real one kills the CLI there), not a bare link-propagated exit.
    assert_received {:transport_terminated, ^transport, :normal}
    refute Process.alive?(transport)

    assert %PhaseResult{status: :error, error: {:deadline_exceeded, 150}} = result
    assert PhaseResult.deadline_exceeded?(result)
    # Same shape as a max-turns kill to the chunk loop: progress stands, the
    # scope is re-dispatched or judged stuck — never retried as a server drop.
    assert PhaseResult.exhausted?(result)
    refute PhaseResult.transient?(result)
    # What the cut stream had already produced is preserved for the Ledger and
    # the transcript.
    assert result.session_id == "sess-cut"
    assert result.final_text =~ "cut at its 0 min deadline"
  end

  test "the deadline fires even when nothing has streamed at all" do
    stream = stuck_stream([], self())

    result = PhaseSession.reduce(stream, 100)

    assert_received {:transport_terminated, _transport, :normal}
    assert PhaseResult.deadline_exceeded?(result)
    assert result.session_id == nil
  end
end
