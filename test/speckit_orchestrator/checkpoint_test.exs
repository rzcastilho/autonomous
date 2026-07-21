defmodule SpeckitOrchestrator.CheckpointTest do
  # async: false — mutates the global :transcript_root app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Checkpoint

  setup do
    root = Path.join(System.tmp_dir!(), "cp_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:speckit_orchestrator, :transcript_root, prev)
    end)

    %{root: root}
  end

  defp checkpoint_path(root, feature_id), do: Path.join([root, feature_id, "checkpoint.json"])

  test "write persists a decodable checkpoint with the diverted phase and status", %{root: root} do
    assert :ok =
             Checkpoint.write(%{
               feature_id: "001",
               last_phase: :clarify,
               status: :escalated,
               reason: "needs human",
               session_id: "s1"
             })

    decoded = root |> checkpoint_path("001") |> File.read!() |> Jason.decode!()

    assert decoded["last_phase"] == "clarify"
    assert decoded["status"] == "escalated"
  end

  test "write records the diverted phase for a halted terminal", %{root: root} do
    assert :ok =
             Checkpoint.write(%{
               feature_id: "002",
               last_phase: :analyze,
               status: :halted,
               reason: "critical finding",
               session_id: "s2"
             })

    decoded = root |> checkpoint_path("002") |> File.read!() |> Jason.decode!()

    assert decoded["last_phase"] == "analyze"
    assert decoded["status"] == "halted"
  end

  test "write serializes a tuple reason via inspect/1 without raising", %{root: root} do
    assert :ok =
             Checkpoint.write(%{
               feature_id: "003",
               last_phase: :implement,
               status: :halted,
               reason: {:breaker, "budget"},
               session_id: "s3"
             })

    decoded = root |> checkpoint_path("003") |> File.read!() |> Jason.decode!()

    assert decoded["reason"] == inspect({:breaker, "budget"})
  end

  test "write to an unwritable transcript root is swallowed and returns :ok" do
    Application.put_env(:speckit_orchestrator, :transcript_root, "/proc/nonexistent/deny")

    assert :ok =
             Checkpoint.write(%{
               feature_id: "004",
               last_phase: :specify,
               status: :failed,
               reason: :timeout,
               session_id: nil
             })
  end

  test "delete removes an existing checkpoint", %{root: root} do
    Checkpoint.write(%{
      feature_id: "005",
      last_phase: :plan,
      status: :halted,
      reason: "critical",
      session_id: "s5"
    })

    assert File.exists?(checkpoint_path(root, "005"))
    assert :ok = Checkpoint.delete("005")
    refute File.exists?(checkpoint_path(root, "005"))
  end

  test "delete on a feature with no checkpoint is a no-op" do
    assert :ok = Checkpoint.delete("no-such-feature")
  end

  test "read for a feature id with no checkpoint returns :no_checkpoint" do
    assert {:error, :no_checkpoint} = Checkpoint.read("no-such-feature")
  end

  test "read on a malformed checkpoint file returns :corrupt", %{root: root} do
    path = checkpoint_path(root, "006")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not valid json{")

    assert {:error, :corrupt} = Checkpoint.read("006")
  end

  test "read on a JSON array (not an object) returns :corrupt", %{root: root} do
    path = checkpoint_path(root, "007")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!([1, 2, 3]))

    assert {:error, :corrupt} = Checkpoint.read("007")
  end

  test "write then read round-trips all fields" do
    Checkpoint.write(%{
      feature_id: "008",
      last_phase: :tasks,
      status: :escalated,
      reason: "needs human",
      session_id: "s8"
    })

    assert {:ok, record} = Checkpoint.read("008")
    assert record["feature_id"] == "008"
    assert record["last_phase"] == "tasks"
    assert record["status"] == "escalated"
    assert record["reason"] == inspect("needs human")
    assert record["session_id"] == "s8"
  end

  test "write given slug/path persists them and read/1 round-trips them losslessly", %{
    root: root
  } do
    assert :ok =
             Checkpoint.write(%{
               feature_id: "009",
               last_phase: :analyze,
               status: :halted,
               reason: "needs human",
               session_id: "s9",
               slug: "widget",
               path: "docs/breakdown/009-widget.md"
             })

    decoded = root |> checkpoint_path("009") |> File.read!() |> Jason.decode!()
    assert decoded["slug"] == "widget"
    assert decoded["path"] == "docs/breakdown/009-widget.md"

    assert {:ok, record} = Checkpoint.read("009")
    assert record["slug"] == "widget"
    assert record["path"] == "docs/breakdown/009-widget.md"
  end

  test "write given an old-shape map without slug/path still writes successfully" do
    assert :ok =
             Checkpoint.write(%{
               feature_id: "010",
               last_phase: :plan,
               status: :halted,
               reason: "needs human",
               session_id: "s10"
             })

    assert {:ok, record} = Checkpoint.read("010")
    assert record["slug"] == nil
    assert record["path"] == nil
  end
end
