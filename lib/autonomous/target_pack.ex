defmodule Autonomous.TargetPack do
  @moduledoc """
  Install and verify the orchestrator's pack in a **target** Spec Kit repo.

  The pack (`priv/target_pack/.claude/`) carries `settings.json` (shell-timeout
  `env`, `permissions.defaultMode`, the `allow` list — never a `deny` list or a
  hook) and the contract marker `autonomous-pack.json`. Committed into the base
  repo, it travels into every worktree.

  039 (pack contract 6): there is one containment behaviour — the container
  (`scripts/autonomous`) is the outer boundary and every orchestrator session
  gets the full tool set. The former `scope_guard.py` PreToolUse hook is gone;
  `install/2` removes a stale copy, and `verify/2` refuses a committed pack
  older than contract 6 on **every** run, so no session can ever meet the old
  hook.

  `install/2` copies the pack **without clobbering** an existing
  `constitution.md` (§4.3: never overwrite the constitution). `verify/2` is the
  preflight: it fails while the shipped template constitution is still in place,
  so a default constitution can never drive a run.
  """

  @template_marker "AUTONOMOUS_TEMPLATE"
  @pack_contract 6
  @marker_rel ".claude/autonomous-pack.json"
  @stale_hook_rel ".claude/hooks/scope_guard.py"

  @outdated_hint "pack is older than contract 6 — run TargetPack.install/2 in the target " <>
                   "repo, commit the result, and re-run"

  @doc "The pack contract this orchestrator requires (039: `6`)."
  @spec contract() :: pos_integer()
  def contract, do: @pack_contract

  @doc """
  Copy the pack into `repo`. Always (over)writes `.claude/settings.json` and
  `.claude/autonomous-pack.json` (they are ours), except that the target's own
  `env` entries in `settings.json` win over the pack's (feature 032, see
  `merge_settings/2`) — every other key is the pack's, so a stale
  `hooks.PreToolUse` scope-guard registration is dropped. Deletes a stale
  `.claude/hooks/scope_guard.py` (and the `hooks/` directory when that leaves
  it empty). Installs the template `constitution.md` only if none exists.
  Returns `{:ok, summary}`, or `{:error, {:invalid_settings, path}}` — before
  writing anything — when the target's `settings.json` is not a JSON object.
  """
  @spec install(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def install(repo, _opts \\ []) do
    with {:ok, settings_out} <- settings_to_write(repo) do
      do_install(repo, settings_out)
    end
  end

  @doc """
  Merge the pack's `settings.json` with a target's existing one. The pack wins
  everywhere except `env`, where the target's keys and values win and only
  absent pack keys are added (feature 032, SC-004).
  """
  @spec merge_settings(map(), map()) :: map()
  def merge_settings(pack, existing) do
    env = Map.merge(Map.get(pack, "env", %{}), Map.get(existing, "env") |> env_map())
    Map.put(pack, "env", env)
  end

  defp env_map(%{} = env), do: env
  defp env_map(_other), do: %{}

  @settings_rel ".claude/settings.json"

  defp settings_to_write(repo) do
    dest = Path.join(repo, @settings_rel)
    pack_src = File.read!(pack("/.claude/settings.json"))

    case File.read(dest) do
      {:error, _reason} ->
        {:ok, pack_src}

      {:ok, existing_src} ->
        case Jason.decode(existing_src) do
          {:ok, %{} = existing} ->
            merged = merge_settings(Jason.decode!(pack_src), existing)

            # Already up to date: keep the bytes, so a re-install is a no-op.
            if merged == existing,
              do: {:ok, existing_src},
              else: {:ok, Jason.encode!(merged, pretty: true) <> "\n"}

          _invalid ->
            {:error, {:invalid_settings, @settings_rel}}
        end
    end
  end

  defp do_install(repo, settings_out) do
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.mkdir_p!(Path.join(repo, ".specify/memory"))

    File.write!(Path.join(repo, @settings_rel), settings_out)
    File.cp!(pack("/.claude/autonomous-pack.json"), Path.join(repo, @marker_rel))

    stale_hook_removed = remove_stale_hook(repo)

    constitution = Path.join(repo, ".specify/memory/constitution.md")

    skipped =
      if File.exists?(constitution) do
        true
      else
        File.cp!(pack("/.specify/memory/constitution.md"), constitution)
        false
      end

    {:ok,
     %{
       settings: true,
       marker: true,
       stale_hook_removed: stale_hook_removed,
       constitution_skipped: skipped
     }}
  end

  defp remove_stale_hook(repo) do
    hook = Path.join(repo, @stale_hook_rel)
    removed? = File.exists?(hook)
    File.rm(hook)

    hooks_dir = Path.dirname(hook)
    if File.dir?(hooks_dir) and File.ls!(hooks_dir) == [], do: File.rmdir(hooks_dir)

    removed?
  end

  @doc """
  Preflight a target `repo`. Returns `:ok` or `{:error, problems}`.

  Checks the pack scaffold is present, that the constitution has been customized
  (template marker gone) and is non-empty, and — unless `check_git: false` — that
  the constitution is committed (git-tracked). Then, on every run (039), the
  pack contract (`check_pack_contract/2`): an older pack is refused with
  `{:pack_outdated, path, hint}`.
  """
  @spec verify(Path.t(), keyword()) :: :ok | {:error, [term()]}
  def verify(repo, opts \\ []) do
    # 039: `:profile` is gone — passing it is a programmer error (raises).
    opts = Keyword.validate!(opts, check_git: true, check_remote: false)
    check_git = Keyword.fetch!(opts, :check_git)

    problems =
      []
      |> require_file(repo, ".claude/settings.json")
      |> require_dir(repo, ".claude/skills")
      |> check_constitution(repo)
      |> check_committed(repo, check_git)
      |> check_remote(repo, Keyword.fetch!(opts, :check_remote))
      |> add_pack_problem(check_pack_contract(repo, check_git))

    case problems do
      [] -> :ok
      _ -> {:error, Enum.reverse(problems)}
    end
  end

  @doc """
  Confirm the pack meets contract 6 (contracts/target-pack.md). With
  `committed? = true` (the default, and every real preflight) it reads the
  **committed** tree (`git -C repo show HEAD:…`) — worktrees are built from it,
  so an uncommitted upgrade does not count; `false` reads the working tree.

    1. `.claude/autonomous-pack.json` exists, decodes, and `contract >= 6`;
    2. `.claude/settings.json` registers no `scope_guard.py` hook and carries
       no `permissions.deny`;
    3. `.claude/hooks/scope_guard.py` is absent.

  The first failure is `{:error, {:pack_outdated, path, hint}}`, `path` naming
  the offending file and `hint` the fix (contract 6, `TargetPack.install/2`,
  commit the result).
  """
  @spec check_pack_contract(Path.t(), boolean()) :: :ok | {:error, term()}
  def check_pack_contract(repo, committed? \\ true) do
    read = fn rel -> read_pack_file(repo, rel, committed?) end

    with :ok <- marker_current(read.(@marker_rel)),
         :ok <- settings_current(read.(@settings_rel)),
         :ok <- stale_hook_absent(read.(@stale_hook_rel)) do
      :ok
    end
  end

  defp marker_current({:ok, src}) do
    case Jason.decode(src) do
      {:ok, %{"contract" => n}} when is_integer(n) and n >= @pack_contract -> :ok
      _ -> outdated(@marker_rel)
    end
  end

  defp marker_current(_missing), do: outdated(@marker_rel)

  defp settings_current({:ok, src}) do
    case Jason.decode(src) do
      {:ok, %{} = settings} ->
        if scope_guard_hook?(settings) or deny?(settings),
          do: outdated(@settings_rel),
          else: :ok

      _ ->
        outdated(@settings_rel)
    end
  end

  defp settings_current(_missing), do: outdated(@settings_rel)

  defp stale_hook_absent({:ok, _src}), do: outdated(@stale_hook_rel)
  defp stale_hook_absent(_missing), do: :ok

  defp outdated(rel), do: {:error, {:pack_outdated, rel, @outdated_hint}}

  defp scope_guard_hook?(settings) do
    settings
    |> get_in(["hooks", "PreToolUse"])
    |> List.wrap()
    |> Enum.flat_map(fn entry -> List.wrap(is_map(entry) && Map.get(entry, "hooks")) end)
    |> Enum.any?(fn hook ->
      is_map(hook) and is_binary(hook["command"]) and
        String.contains?(hook["command"], "scope_guard.py")
    end)
  end

  defp deny?(%{"permissions" => %{"deny" => deny}}) when is_list(deny), do: deny != []
  defp deny?(_settings), do: false

  defp read_pack_file(repo, rel, true), do: git_show(repo, rel)
  defp read_pack_file(repo, rel, false), do: File.read(Path.join(repo, rel))

  defp add_pack_problem(problems, :ok), do: problems
  defp add_pack_problem(problems, {:error, reason}), do: [reason | problems]

  defp git_show(repo, rel) do
    case System.cmd("git", ["-C", repo, "show", "HEAD:#{rel}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, _code} -> {:error, :git_show_failed}
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

  # `check_remote:` — `false` (default) skips; `true` checks the configured
  # `pr_remote`; a string checks that named remote. Used by the PR workflow's
  # preflight so a run cannot start without a push target.
  defp check_remote(problems, _repo, false), do: problems

  defp check_remote(problems, repo, true),
    do: check_remote(problems, repo, Autonomous.Config.pr_remote())

  defp check_remote(problems, repo, remote) when is_binary(remote) do
    case System.cmd("git", ["-C", repo, "remote", "get-url", remote], stderr_to_stdout: true) do
      {_, 0} -> problems
      {_, _} -> [{:no_remote, remote} | problems]
    end
  end

  # ---- pack location ------------------------------------------------------

  defp pack(rel), do: Path.join(:code.priv_dir(:autonomous), "target_pack" <> rel)
end
