defmodule SpeckitOrchestrator.TargetPack do
  @moduledoc """
  Install and verify the orchestrator's enforcement pack in a **target** Spec Kit
  repo.

  The pack (`priv/target_pack/.claude/`) carries a least-privilege
  `settings.json` and the PreToolUse `scope_guard.py` hook that denies
  out-of-tree writes and dangerous Bash — the real containment layer, since the
  adapter runs the CLI with `--dangerously-skip-permissions`. Committed into the
  base repo, it travels into every worktree.

  `install/2` copies the pack **without clobbering** an existing
  `constitution.md` (§4.3: never overwrite the constitution). `verify/1` is the
  preflight: it fails while the shipped template constitution is still in place,
  so a default constitution can never drive a run.
  """

  @template_marker "SPECKIT_ORCHESTRATOR_TEMPLATE"

  @doc """
  Copy the pack into `repo`. Always (over)writes `.claude/settings.json` and
  `.claude/hooks/scope_guard.py` (they are ours); installs the template
  `constitution.md` only if none exists. Returns `{:ok, summary}`.
  """
  @spec install(Path.t(), keyword()) :: {:ok, map()}
  def install(repo, _opts \\ []) do
    File.mkdir_p!(Path.join(repo, ".claude/hooks"))
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.mkdir_p!(Path.join(repo, ".specify/memory"))

    File.cp!(pack("/.claude/settings.json"), Path.join(repo, ".claude/settings.json"))

    hook_dest = Path.join(repo, ".claude/hooks/scope_guard.py")
    File.cp!(pack("/.claude/hooks/scope_guard.py"), hook_dest)
    File.chmod!(hook_dest, 0o755)

    constitution = Path.join(repo, ".specify/memory/constitution.md")

    skipped =
      if File.exists?(constitution) do
        true
      else
        File.cp!(pack("/.specify/memory/constitution.md"), constitution)
        false
      end

    {:ok, %{settings: true, hook: true, constitution_skipped: skipped}}
  end

  @doc """
  Preflight a target `repo`. Returns `:ok` or `{:error, problems}`.

  Checks the pack scaffold is present, that the constitution has been customized
  (template marker gone) and is non-empty, and — unless `check_git: false` — that
  the constitution is committed (git-tracked).
  """
  @spec verify(Path.t(), keyword()) :: :ok | {:error, [term()]}
  def verify(repo, opts \\ []) do
    problems =
      []
      |> require_file(repo, ".claude/settings.json")
      |> require_file(repo, ".claude/hooks/scope_guard.py")
      |> require_dir(repo, ".claude/skills")
      |> check_constitution(repo)
      |> check_committed(repo, Keyword.get(opts, :check_git, true))

    case problems do
      [] -> :ok
      _ -> {:error, Enum.reverse(problems)}
    end
  end

  # ---- checks -------------------------------------------------------------

  defp require_file(problems, repo, rel) do
    if File.regular?(Path.join(repo, rel)), do: problems, else: [{:missing, rel} | problems]
  end

  defp require_dir(problems, repo, rel) do
    if File.dir?(Path.join(repo, rel)), do: problems, else: [{:missing, rel} | problems]
  end

  defp check_constitution(problems, repo) do
    path = Path.join(repo, ".specify/memory/constitution.md")

    case File.read(path) do
      {:error, _} ->
        [{:missing, ".specify/memory/constitution.md"} | problems]

      {:ok, content} ->
        cond do
          String.contains?(content, @template_marker) ->
            [{:default_constitution, "still the shipped template — customize it"} | problems]

          String.trim(content) == "" ->
            [{:empty_constitution, path} | problems]

          true ->
            problems
        end
    end
  end

  defp check_committed(problems, _repo, false), do: problems

  defp check_committed(problems, repo, true) do
    rel = ".specify/memory/constitution.md"

    case System.cmd("git", ["-C", repo, "ls-files", "--error-unmatch", rel],
           stderr_to_stdout: true
         ) do
      {_, 0} -> problems
      {_, _} -> [{:uncommitted, rel} | problems]
    end
  end

  # ---- pack location ------------------------------------------------------

  defp pack(rel), do: Path.join(:code.priv_dir(:speckit_orchestrator), "target_pack" <> rel)
end
