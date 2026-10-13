defmodule Autonomous.VolumesCase do
  @moduledoc """
  Case template for `scripts/volumes.py` tests (feature 041).

  Hermetic: every test gets its own temp `XDG_CONFIG_HOME`; Python runs isolated
  (`-I`) so nothing from the working directory is imported.
  """
  use ExUnit.CaseTemplate

  @script Path.expand("../../scripts/volumes.py", __DIR__)

  using do
    quote do
      import Autonomous.VolumesCase
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "volumes_#{System.unique_integer([:positive])}")
    xdg = Path.join(base, "xdg")
    File.mkdir_p!(xdg)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, context(base, xdg)}
  end

  @doc "The canonical instance context handed to the validator/planner."
  def context(base, xdg) do
    %{
      repo: "/home/autonomous/target",
      worktree_root: "/home/autonomous/.autonomous/worktrees/t-1a2b",
      state_root: "/home/autonomous/.autonomous",
      segment: "t-1a2b",
      uid: 1000,
      gid: 1000,
      image_env: %{},
      xdg: xdg,
      base: base
    }
  end

  @doc "Declaration path for the context's segment."
  def declaration_path(%{xdg: xdg, segment: segment}),
    do: Path.join([xdg, "autonomous", "targets", segment, "volumes.toml"])

  @doc "Writes `text` as the context's declaration and returns its path."
  def write_declaration(ctx, text) do
    path = declaration_path(ctx)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  @doc "Runs `scripts/volumes.py` with `args`; returns `{output, exit_status}`."
  def run_volumes(args, ctx) do
    System.cmd("python3", ["-I", @script | args],
      env: [{"XDG_CONFIG_HOME", ctx.xdg}],
      stderr_to_stdout: true
    )
  end

  @doc """
  Calls `volumes.parse/1` in isolated Python. Returns `{:ok, entries}` or
  `{:malformed, message}`.
  """
  def parse_text(text) do
    code = """
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("volumes", sys.argv[1])
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    try:
        print(json.dumps(m.parse(sys.stdin.read(), "volumes.toml")))
    except m.Malformed as e:
        print(str(e)); sys.exit(2)
    """

    parse_via_file(code, text)
  end

  defp parse_via_file(code, text) do
    file = Path.join(System.tmp_dir!(), "volumes_in_#{System.unique_integer([:positive])}.toml")
    File.write!(file, text)

    try do
      {out, status} =
        System.cmd(
          "sh",
          ["-c", ~s(python3 -I -c "$1" "$2" < "$3"), "sh", code, @script, file],
          env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
          stderr_to_stdout: true
        )

      case status do
        0 -> {:ok, out |> String.trim() |> :json.decode()}
        _ -> {:malformed, String.trim(out)}
      end
    after
      File.rm(file)
    end
  end
end
