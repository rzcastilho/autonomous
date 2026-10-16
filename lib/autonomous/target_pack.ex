defmodule Autonomous.TargetPack do
  @moduledoc """
  Supply and verify the orchestrator's pack for a **target** Spec Kit repo.

  The pack (`priv/target_pack/.claude/`) carries `settings.json` (shell-timeout
  `env`, `permissions.defaultMode`, the `allow` list — never a `deny` list or a
  hook) and the contract marker `autonomous-pack.json`.

  044: the orchestrator owns the pack. `supply/1` writes it into every feature
  worktree — the marker as `.claude/autonomous-pack.json` and the pack settings
  as `.claude/settings.local.json` (minus any `env` key the target's own tracked
  `settings.json` sets, so the operator's value wins) — and keeps both untracked
  through a marked block in the target's common-dir `info/exclude`. It never
  writes, merges or deletes a tracked file. A target may still commit a pack;
  one that meets the contract is used as-is, an older one is refused (both
  remedies named). `verify/2` therefore no longer requires the pack files.

  039 (pack contract 6, unchanged): there is one containment behaviour — the
  container (`scripts/autonomous`) is the outer boundary and every orchestrator
  session gets the full tool set. The former `scope_guard.py` PreToolUse hook is
  gone; `verify/2` refuses a committed pack older than contract 6 on **every**
  run, so no session can ever meet the old hook.

  `install/2` is the manual, optional path for a checkout the operator drives
  themself; it never overwrites `settings.json` and **never clobbers** an
  existing `constitution.md` (§4.3). `verify/2` is the preflight: it fails while
  the shipped template constitution is still in place, so a default constitution
  can never drive a run.
  """

  @template_marker "AUTONOMOUS_TEMPLATE"
  @pack_contract 6
  @marker_rel ".claude/autonomous-pack.json"
  @settings_rel ".claude/settings.json"
  @local_rel ".claude/settings.local.json"
  @stale_hook_rel ".claude/hooks/scope_guard.py"

  @exclude_header "# autonomous: orchestrator-supplied pack (feature 044) — do not edit this block"
  @exclude_patterns ["/" <> @marker_rel, "/" <> @local_rel]

  @outdated_hint "pack is older than contract 6 — either update the tracked file to contract 6 " <>
                   "and commit it, or remove the pack files from version control " <>
                   "(`git rm --cached <file>`, commit) so the orchestrator supplies them"

  @local_tracked_hint "the orchestrator supplies `.claude/settings.local.json` into each " <>
                        "worktree — stop tracking it (`git rm --cached .claude/settings.local.json`, " <>
                        "commit) and re-run"

  @doc "The pack contract this orchestrator requires (039: `6`)."
  @spec contract() :: pos_integer()
  def contract, do: @pack_contract

  @doc """
  Derive the `settings.local.json` content from the pack's settings and the
  target's tracked `settings.json` (`nil` when it has none). Claude Code's
  local settings outrank project settings, so the local file must not restate
  an `env` key the tracked file sets: those keys are dropped, and `env` itself
  when nothing is left. Every other key is the pack's, verbatim (044, FR-006).
  """
  @spec local_settings(map(), map() | nil) :: map()
  def local_settings(pack, tracked) do
    tracked_keys = tracked |> tracked_env() |> Map.keys()
    env = pack |> Map.get("env") |> env_map() |> Map.drop(tracked_keys)

    if env == %{}, do: Map.delete(pack, "env"), else: Map.put(pack, "env", env)
  end

  defp tracked_env(%{"env" => env}), do: env_map(env)
  defp tracked_env(_other), do: %{}

  defp env_map(%{} = env), do: env
  defp env_map(_other), do: %{}

  @doc """
  Manually install the pack into `dir` (optional — runs do not need it). Writes
  `.claude/settings.local.json` (see `local_settings/2`) and the contract
  marker, each only when it would change; **never writes `.claude/settings.json`**.
  Deletes a stale `.claude/hooks/scope_guard.py` (and the `hooks/` directory when
  that leaves it empty). Installs the template `constitution.md` only if none
  exists. Returns `{:ok, summary}` — `settings`/`marker` say what was written
  this call — or `{:error, {:invalid_settings, path}}`, before writing anything,
  when the target's `settings.json` is not a JSON object.
  """
  @spec install(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def install(repo, _opts \\ []) do
    with {:ok, tracked} <- read_tracked_settings(repo) do
      File.mkdir_p!(Path.join(repo, ".claude/skills"))
      File.mkdir_p!(Path.join(repo, ".specify/memory"))

      summary = write_pack(repo, tracked)
      constitution = Path.join(repo, ".specify/memory/constitution.md")

      skipped =
        if File.exists?(constitution) do
          true
        else
          File.cp!(pack("/.specify/memory/constitution.md"), constitution)
          false
        end

      {:ok, Map.put(summary, :constitution_skipped, skipped)}
    end
  end

  defp read_tracked_settings(repo) do
    case File.read(Path.join(repo, @settings_rel)) do
      {:error, _reason} ->
        {:ok, nil}

      {:ok, src} ->
        case Jason.decode(src) do
          {:ok, %{} = settings} -> {:ok, settings}
          _invalid -> {:error, {:invalid_settings, @settings_rel}}
        end
    end
  end

  # The pack half of `install/2` and `supply/1`: local settings, marker, stale hook.
  defp write_pack(dir, tracked) do
    File.mkdir_p!(Path.join(dir, ".claude"))

    local_src =
      pack("/.claude/settings.json")
      |> File.read!()
      |> Jason.decode!()
      |> local_settings(tracked)
      |> Jason.encode!(pretty: true)
      |> Kernel.<>("\n")

    settings_written = write_if_changed(Path.join(dir, @local_rel), local_src)
    marker_written = write_marker(dir)

    %{
      settings: settings_written,
      marker: marker_written,
      stale_hook_removed: remove_stale_hook(dir)
    }
  end

  defp write_if_changed(path, content) do
    if File.read(path) == {:ok, content} do
      false
    else
      File.write!(path, content)
      true
    end
  end

  defp write_marker(dir) do
    dest = Path.join(dir, @marker_rel)

    current? =
      case File.read(dest) do
        {:ok, src} ->
          match?(
            {:ok, %{"contract" => n}} when is_integer(n) and n >= @pack_contract,
            Jason.decode(src)
          )

        {:error, _} ->
          false
      end

    if current? do
      false
    else
      File.cp!(pack("/.claude/autonomous-pack.json"), dest)
      true
    end
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
  Supply the pack into a feature `worktree` (044) — called by
  `Worktree.create/2` and `Worktree.restore/1`, never on the target checkout.

    1. inspect the worktree's **tracked** pack files (same rules as
       `check_pack_contract/2`); an outdated pack, a tracked
       `settings.local.json` or an invalid tracked `settings.json` is refused;
    2. add the marked block to the shared `info/exclude` (idempotent);
    3. write `settings.local.json` and the marker where they would change.

  Never writes, merges or deletes a tracked path. Returns
  `{:ok, %{source, wrote, excluded}}` — `wrote`/`excluded` are empty on a
  worktree that is already supplied.
  """
  @spec supply(Path.t()) :: {:ok, map()} | {:error, term()}
  def supply(worktree) do
    with :ok <- do_check(worktree, :tracked),
         {:ok, tracked} <- tracked_settings(worktree),
         {:ok, excluded} <- ensure_excluded(worktree) do
      summary = write_pack(worktree, tracked)

      wrote =
        [{summary.settings, @local_rel}, {summary.marker, @marker_rel}]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      source = if tracked?(worktree, @marker_rel), do: :committed, else: :supplied
      {:ok, %{source: source, wrote: wrote, excluded: excluded}}
    end
  end

  defp tracked_settings(worktree) do
    case read_pack_file(worktree, @settings_rel, :tracked) do
      {:ok, src} ->
        case Jason.decode(src) do
          {:ok, %{} = settings} -> {:ok, settings}
          _ -> {:error, {:invalid_settings, @settings_rel}}
        end

      :absent ->
        {:ok, nil}
    end
  end

  # Append the 044 block to `<git-common-dir>/info/exclude`, writing each line
  # only when absent as an exact line. Returns the patterns added.
  defp ensure_excluded(dir) do
    with {:ok, common} <- git_out(dir, ["rev-parse", "--git-common-dir"]),
         info = Path.join(Path.expand(common, dir), "info"),
         path = Path.join(info, "exclude"),
         :ok <- File.mkdir_p(info),
         {:ok, existing} <- read_or_empty(path) do
      lines = String.split(existing, "\n")
      missing = Enum.reject(@exclude_patterns, &(&1 in lines))

      if missing == [] do
        {:ok, []}
      else
        header = if @exclude_header in lines, do: [], else: [@exclude_header]
        lead = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
        block = lead <> Enum.map_join(header ++ missing, "", &(&1 <> "\n"))

        case File.write(path, block, [:append]) do
          :ok -> {:ok, missing}
          {:error, reason} -> {:error, {:exclude_failed, reason}}
        end
      end
    else
      {:error, reason} -> {:error, {:exclude_failed, reason}}
    end
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, src} -> {:ok, src}
      {:error, :enoent} -> {:ok, ""}
      {:error, _} = err -> err
    end
  end

  defp git_out(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:git_failed, code, String.trim(out)}}
    end
  end

  @doc """
  Where the pack comes from for `repo`'s committed tree (044, R8):
  `{:ok, %{source: :supplied | :committed, contract: n}}` — `:supplied` when no
  pack marker is tracked — or the same refusal `verify/2` reports.
  """
  @spec source(Path.t()) ::
          {:ok, %{source: :supplied | :committed, contract: pos_integer()}} | {:error, term()}
  def source(repo) do
    with :ok <- do_check(repo, :head) do
      case read_pack_file(repo, @marker_rel, :head) do
        {:ok, src} ->
          %{"contract" => n} = Jason.decode!(src)
          {:ok, %{source: :committed, contract: n}}

        :absent ->
          {:ok, %{source: :supplied, contract: @pack_contract}}
      end
    end
  end

  @doc """
  Preflight a target `repo`. Returns `:ok` or `{:error, problems}`.

  Checks the `.claude/skills` scaffold is present, that the constitution has been
  customized (template marker gone) and is non-empty, and — unless
  `check_git: false` — that the constitution is committed (git-tracked). Then,
  on every run (039), the pack contract (`check_pack_contract/2`): a committed
  pack older than contract 6 is refused with `{:pack_outdated, path, hint}`. The
  pack files themselves are not required (044) — the orchestrator supplies them.
  """
  @spec verify(Path.t(), keyword()) :: :ok | {:error, [term()]}
  def verify(repo, opts \\ []) do
    # 039: `:profile` is gone — passing it is a programmer error (raises).
    opts = Keyword.validate!(opts, check_git: true, check_remote: false)
    check_git = Keyword.fetch!(opts, :check_git)

    problems =
      []
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
  Confirm any pack the target commits meets contract 6 (contracts/target-pack.md).
  With `committed? = true` (the default, and every real preflight) it reads the
  **committed** tree (`git -C repo show HEAD:…`) — worktrees are built from it,
  so an uncommitted upgrade does not count; `false` reads the working tree. A
  file that is absent is fine (044 — the orchestrator supplies the pack). First
  failure wins:

    1. `.claude/autonomous-pack.json`, when present, decodes with `contract >= 6`;
    2. `.claude/settings.json`, when present, is a JSON object that registers no
       `scope_guard.py` hook and carries no `permissions.deny`;
    3. `.claude/hooks/scope_guard.py` is absent;
    4. `.claude/settings.local.json` is not tracked (committed mode only).

  Refusals: `{:pack_outdated, path, hint}`, `{:invalid_settings, path}`,
  `{:pack_local_tracked, path, hint}`.
  """
  @spec check_pack_contract(Path.t(), boolean()) :: :ok | {:error, term()}
  def check_pack_contract(repo, committed? \\ true),
    do: do_check(repo, if(committed?, do: :head, else: :files))

  # `mode`: `:head` reads `git show HEAD:…`; `:files` reads the working tree;
  # `:tracked` reads the working tree but only for paths git tracks (a supplied,
  # untracked file is not the target's pack).
  defp do_check(repo, mode) do
    read = fn rel -> read_pack_file(repo, rel, mode) end

    with :ok <- marker_current(read.(@marker_rel)),
         :ok <- settings_current(read.(@settings_rel)),
         :ok <- stale_hook_absent(read.(@stale_hook_rel)),
         :ok <- local_untracked(repo, mode) do
      :ok
    end
  end

  defp marker_current({:ok, src}) do
    case Jason.decode(src) do
      {:ok, %{"contract" => n}} when is_integer(n) and n >= @pack_contract -> :ok
      _ -> outdated(@marker_rel)
    end
  end

  defp marker_current(:absent), do: :ok

  defp settings_current({:ok, src}) do
    case Jason.decode(src) do
      {:ok, %{} = settings} ->
        if scope_guard_hook?(settings) or deny?(settings),
          do: outdated(@settings_rel),
          else: :ok

      _ ->
        {:error, {:invalid_settings, @settings_rel}}
    end
  end

  defp settings_current(:absent), do: :ok

  defp stale_hook_absent({:ok, _src}), do: outdated(@stale_hook_rel)
  defp stale_hook_absent(:absent), do: :ok

  defp local_untracked(_repo, :files), do: :ok

  defp local_untracked(repo, mode) do
    tracked? =
      case mode do
        :head -> match?({:ok, _}, git_show(repo, @local_rel))
        :tracked -> tracked?(repo, @local_rel)
      end

    if tracked?, do: {:error, {:pack_local_tracked, @local_rel, @local_tracked_hint}}, else: :ok
  end

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

  defp read_pack_file(repo, rel, :head), do: git_show(repo, rel)

  defp read_pack_file(repo, rel, :files) do
    case File.read(Path.join(repo, rel)) do
      {:ok, src} -> {:ok, src}
      {:error, _} -> :absent
    end
  end

  defp read_pack_file(repo, rel, :tracked) do
    if tracked?(repo, rel), do: read_pack_file(repo, rel, :files), else: :absent
  end

  defp tracked?(repo, rel) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", repo, "ls-files", "--error-unmatch", rel], stderr_to_stdout: true)
    )
  end

  defp add_pack_problem(problems, :ok), do: problems
  defp add_pack_problem(problems, {:error, reason}), do: [reason | problems]

  defp git_show(repo, rel) do
    case System.cmd("git", ["-C", repo, "show", "HEAD:#{rel}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, _code} -> :absent
    end
  end

  # ---- checks -------------------------------------------------------------

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
