defmodule Autonomous.ConversationIsolationTest do
  # SC-004 / FR-005: capture and viewing never change a session. The same
  # scripted session runs with no viewer, a never-reading viewer and a killed
  # recorder; its outcome, result and gate signals are identical.
  use ExUnit.Case, async: false

  alias Autonomous.{Conversation, FakeSdk, Feature, Layout}
  alias Autonomous.Actions.RunFeaturePhase

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    prev = Application.get_env(:autonomous, :sdk_proxy_inner)
    Application.put_env(:autonomous, :sdk_proxy_inner, FakeSdk)
    FakeSdk.configure(frames: FakeSdk.default_frames("sess-iso"))

    on_exit(fn ->
      FakeSdk.reset()

      if prev,
        do: Application.put_env(:autonomous, :sdk_proxy_inner, prev),
        else: Application.delete_env(:autonomous, :sdk_proxy_inner)
    end)

    state = %{
      feature: %Feature{id: "001", number: 1, slug: "s", path: "p.md"},
      worktree: nil,
      layout: %Layout{worktree_root: root, transcript_root: root, in_repo_rel: "docs/breakdown"},
      run_key: {"o:repo", "r000001"},
      ledger: nil,
      session_id: nil,
      history: [],
      cost_total: 0.0,
      phase: :clarify,
      resume_phase: nil,
      resume_prompt: nil,
      last_signals: %{},
      conversations: []
    }

    %{state: state}
  end

  defp run(state), do: RunFeaturePhase.run(%{phase: :clarify}, %{agent: %{state: state}})

  defp outcome({:ok, update}),
    do: Map.take(update, [:last_outcome, :last_signals, :session_id, :cost_total])

  test "zero viewers, a never-reading viewer and a killed recorder give the same outcome", %{
    state: state
  } do
    baseline = run(state)
    assert {:ok, %{last_outcome: :ok, conversations: [%{status: :captured}]}} = baseline

    # A subscriber that never reads its mailbox.
    stuck = spawn(fn -> Process.sleep(:infinity) end)

    FakeSdk.configure(frames: FakeSdk.default_frames("sess-iso"), delay_ms: 5)

    watcher =
      Task.async(fn ->
        wait_for_session()
        [%{conversation_id: id}] = Conversation.in_flight(nil)
        Phoenix.PubSub.subscribe(Autonomous.PubSub, "conversation:" <> id)
        :ok
      end)

    viewed = run(state)
    Task.await(watcher)
    Process.exit(stuck, :kill)

    assert outcome(viewed) == outcome(baseline)
    assert {:ok, %{conversations: [%{status: :captured}]}} = viewed

    # Recorder killed mid-session.
    killer =
      Task.async(fn ->
        wait_for_session()
        [%{conversation_id: id}] = Conversation.in_flight(nil)
        wait_for_entries(id, 3)
        [{pid, _}] = Registry.lookup(Autonomous.ConversationRegistry, id)
        Process.exit(pid, :kill)
      end)

    killed = run(state)
    Task.await(killer)

    assert outcome(killed) == outcome(baseline)
    assert {:ok, %{conversations: [%{status: :partial, reason: :recorder_down}]}} = killed
  end

  defp wait_for_entries(id, n) do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      case Conversation.catch_up(id) do
        {:ok, entries, _, _} when length(entries) >= n -> {:halt, :ok}
        _ -> Process.sleep(2) && {:cont, nil}
      end
    end)
  end

  defp wait_for_session do
    Enum.reduce_while(1..400, nil, fn _, _ ->
      if Conversation.in_flight(nil) == [],
        do:
          (
            Process.sleep(2)
            {:cont, nil}
          ),
        else: {:halt, :ok}
    end)
  end
end
