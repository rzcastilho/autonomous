defmodule Autonomous.TargetPack do
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

  @template_marker "AUTONOMOUS_TEMPLATE"
  @pack_contract "4"

  @doc """
  Copy the pack into `repo`. Always (over)writes `.claude/settings.json` and
  `.claude/hooks/scope_guard.py` (they are ours), except that the target's own
  `env` entries in `settings.json` win over the pack's (feature 032, see
  `merge_settings/2`); installs the template `constitution.md` only if none
  exists. Returns `{:ok, summary}`, or `{:error, {:invalid_settings, path}}`
  — before writing anything — when the target's `settings.json` is not a JSON
  object.
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
    File.mkdir_p!(Path.join(repo, ".claude/hooks"))
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.mkdir_p!(Path.join(repo, ".specify/memory"))

    File.write!(Path.join(repo, @settings_rel), settings_out)

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

  `:profile` (030, default `"strict"`) — `"permissive"` adds
  `check_pack_contract/2`: the **committed** pack must carry hook contract 4
  and a `settings.json` with no `permissions.deny` entry, or the run refuses
  with `{:pack_outdated, path, hint}`. `"strict"` is unchanged from today —
  an un-upgraded target still enforces its own (older) rules and does not
  fail preflight.
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
      |> check_remote(repo, Keyword.get(opts, :check_remote, false))
      |> check_pack_contract(repo, Keyword.get(opts, :profile, "strict"))

    case problems do
      [] -> :ok
      _ -> {:error, Enum.reverse(problems)}
    end
  end

  @doc """
  Read the **committed** pack (`git -C repo show HEAD:…`) and confirm it is
  contract 4: the hook prints `4` for `--contract`, and `settings.json` carries
  no non-empty `permissions.deny`. Any failure (git show failure — including an
  uncommitted upgrade — a non-`"4"` contract output, or a present `deny`) is
  `{:pack_outdated, ".claude/hooks/scope_guard.py", "re-run TargetPack.install/2 and commit"}`.
  """
  @spec check_pack_contract(Path.t()) :: :ok | {:error, term()}
  def check_pack_contract(repo) do
    with {:ok, hook_src} <- git_show(repo, ".claude/hooks/scope_guard.py"),
         {:ok, @pack_contract} <- contract_of(hook_src),
         {:ok, settings_src} <- git_show(repo, ".claude/settings.json"),
         :ok <- no_deny?(settings_src) do
      :ok
    else
      _ ->
        {:error,
         {:pack_outdated, ".claude/hooks/scope_guard.py",
          "re-run TargetPack.install/2 and commit"}}
    end
  end

  defp git_show(repo, rel) do
    case System.cmd("git", ["-C", repo, "show", "HEAD:#{rel}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, _code} -> {:error, :git_show_failed}
    end
  end

  defp contract_of(hook_src) do
    tmp = Path.join(System.tmp_dir!(), "scope_guard_#{System.unique_integer([:positive])}.py")
    File.write!(tmp, hook_src)

    result =
      case System.cmd("python3", [tmp, "--contract"], stderr_to_stdout: true) do
        {out, 0} -> {:ok, String.trim(out)}
        {_out, _code} -> {:error, :contract_probe_failed}
      end

    File.rm(tmp)
    result
  end

  defp no_deny?(settings_src) do
    case Jason.decode(settings_src) do
      {:ok, %{"permissions" => %{"deny" => deny}}} when is_list(deny) and deny != [] ->
        {:error, :deny_present}

      {:ok, _decoded} ->
        :ok

      {:error, _reason} ->
        {:error, :bad_json}
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

  defp check_pack_contract(problems, _repo, "strict"), do: problems

  defp check_pack_contract(problems, repo, "permissive") do
    case check_pack_contract(repo) do
      :ok -> problems
      {:error, reason} -> [reason | problems]
    end
  end

  # ---- pack location ------------------------------------------------------

  defp pack(rel), do: Path.join(:code.priv_dir(:autonomous), "target_pack" <> rel)
end
