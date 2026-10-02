defmodule Mix.Tasks.Autonomous.Instance do
  @shortdoc "Print the derived instance identity for a target repository"

  @moduledoc """
  Prints the per-target instance identity (feature 031).

      mix autonomous.instance --repo <path> [--root <path>] [--format env|segment|json]

  `env` (default) prints `KEY=value` lines for the five `AUTONOMOUS_*` identity
  variables; `segment` prints the bare segment; `json` prints the whole identity.
  Exits 1 when `--repo` is not a git repository.

  The application is **not** started (`app.config` loads configuration only),
  so the container guard and the store are never touched. The entrypoint and
  the wrapper are the only intended callers; the derivation itself lives in
  `Autonomous.Instance`.
  """

  use Mix.Task

  alias Autonomous.{Config, Instance, RepoIdentity}

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv, strict: [repo: :string, root: :string, format: :string])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    repo = opts |> Keyword.get_lazy(:repo, fn -> Mix.raise("--repo is required") end) |> Path.expand()
    root = opts |> Keyword.get_lazy(:root, &Config.autonomous_root/0) |> Path.expand()

    unless git_repo?(repo) do
      Mix.shell().error("#{repo} is not a git repository")
      exit({:shutdown, 1})
    end

    identity = Instance.derive(repo, RepoIdentity.partition(repo), root)

    case Keyword.get(opts, :format, "env") do
      "env" -> identity |> Instance.env_lines() |> Enum.each(fn line -> Mix.shell().info(line) end)
      "segment" -> Mix.shell().info(identity.segment)
      "json" -> Mix.shell().info(json(identity))
      other -> Mix.raise("unknown --format #{inspect(other)} (env|segment|json)")
    end
  end

  defp git_repo?(path) do
    match?({_, 0}, System.cmd("git", ["-C", path, "rev-parse", "--git-dir"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp json(identity) do
    identity |> Map.from_struct() |> Map.update!(:node_name, &Atom.to_string/1) |> Jason.encode!()
  end
end
