defmodule SpeckitOrchestrator.Preflight do
  @moduledoc """
  The FR-032 environment verification run before any feature work.

  `collect/1` does IO — probing tools, credentials, mounts, path identity, and
  target-repo readiness — behind injectable seams (tool lookup, mountinfo
  contents, writability, `TargetPack.verify/1`, the image manifest, the
  container-detection signal, the effective uid). `evaluate/1` is pure: a
  collected-facts map in, a `Report.t()` out, so every failure mode
  (`contracts/preflight-report.md` §3) is unit-tested with no container or
  CLI (Constitution I, matching the `:runner`-seam discipline the constitution
  already requires for wave/DAG/breaker logic). `persist/2` writes the
  pretty-printed report; `run/1` composes all three.

  Credential checks record **source** only (`:env` / `:mounted_config` /
  `:absent`) — never a value, prefix, or length (FR-035).
  """

  alias SpeckitOrchestrator.Config
  alias SpeckitOrchestrator.Container.{Env, Mount}
  alias SpeckitOrchestrator.ImageInfo
  alias SpeckitOrchestrator.Preflight.{Check, Report}
  alias SpeckitOrchestrator.TargetPack

  @tools ~w(git gh claude specify python3 mise)

  # ---------------------------------------------------------------------
  # collect/1 — IO boundary
  # ---------------------------------------------------------------------

  @doc """
  Probe the environment for every fact `evaluate/1` needs. Accepts injected
  seams (all optional, defaulting to real IO) so every failure mode is
  independently fakeable in the hermetic suite:

    * `:env` — a `Container.Env.t()`, default `Container.Env.load!/0`
    * `:tool_probe` — `(tool_name) -> {:ok, version} | :error`
    * `:mountinfo_read` — `() -> {:ok, contents} | {:error, term}`
    * `:writable?` — `(path) -> boolean`
    * `:target_pack_verify` — `(repo) -> :ok | {:error, term}`
    * `:image_read` — `() -> {:ok, ImageInfo.t()} | {:error, :not_containerized}`
    * `:containerized?` — `() -> boolean`, default probes `/.dockerenv`
    * `:euid` — `() -> non_neg_integer()`
    * `:home_env` — the resolved `$HOME`, default `System.get_env("HOME")`
    * `:claude_config_present?` — `() -> boolean`
    * `:gh_token_present?` — `boolean`
    * `:anthropic_key_present?` — `boolean`
  """
  @spec collect(keyword()) :: map()
  def collect(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &Env.load!/0)
    repo = Keyword.get(opts, :repo, env.repo)
    run_state_root = Keyword.get_lazy(opts, :run_state_root, &Config.autonomous_root/0)
    tool_probe = Keyword.get(opts, :tool_probe, &default_tool_probe/1)
    mountinfo_read = Keyword.get(opts, :mountinfo_read, &default_mountinfo_read/0)
    writable? = Keyword.get(opts, :writable?, &default_writable?/1)
    target_pack_verify = Keyword.get(opts, :target_pack_verify, &TargetPack.verify/1)
    image_read = Keyword.get(opts, :image_read, &ImageInfo.read/0)
    containerized? = Keyword.get(opts, :containerized?, &default_containerized?/0)
    euid = Keyword.get(opts, :euid, &default_euid/0)
    home_env = Keyword.get(opts, :home_env, System.get_env("HOME"))

    claude_config_present? =
      Keyword.get(opts, :claude_config_present?, fn -> default_claude_config_present?(home_env) end)

    gh_token_present? = Keyword.get(opts, :gh_token_present?, System.get_env("GH_TOKEN") != nil)

    anthropic_key_present? =
      Keyword.get(
        opts,
        :anthropic_key_present?,
        System.get_env("ANTHROPIC_API_KEY") != nil or System.get_env("ANTHROPIC_AUTH_TOKEN") != nil
      )

    image =
      case image_read.() do
        {:ok, info} -> info
        {:error, :not_containerized} -> nil
      end

    tools = for tool <- @tools, into: %{}, do: {tool, tool_probe.(tool)}

    run_state_mount_point? =
      case mountinfo_read.() do
        {:ok, contents} -> Mount.mount_point?(contents, run_state_root)
        {:error, _} -> false
      end

    %{
      repo: repo,
      run_state_root: run_state_root,
      collected_at: DateTime.utc_now(),
      image: image,
      containerized?: containerized?.(),
      env: env,
      tools: tools,
      pr_workflow?: env.pr_workflow?,
      speckit_version: Config.speckit_version(),
      gh_token_present?: gh_token_present?,
      credential_source: credential_source(anthropic_key_present?, claude_config_present?.()),
      repo_path_exists?: File.dir?(repo),
      repo_git_worktree?: File.dir?(Path.join(repo, ".git")) or File.regular?(Path.join(repo, ".git")),
      repo_writable?: writable?.(repo),
      home_env: home_env,
      run_state_writable?: writable?.(run_state_root),
      run_state_mount_point?: run_state_mount_point?,
      target_pack_result: target_pack_verify.(repo),
      euid: euid.()
    }
  end

  defp credential_source(true, _mounted?), do: :env
  defp credential_source(false, true), do: :mounted_config
  defp credential_source(false, false), do: :absent

  defp default_tool_probe(tool) do
    case System.find_executable(tool) do
      nil ->
        :error

      _path ->
        case System.cmd(tool, ["--version"], stderr_to_stdout: true) do
          {out, 0} -> {:ok, extract_version(out)}
          _ -> :error
        end
    end
  end

  defp extract_version(out) do
    case Regex.run(~r/(\d+\.\d+(?:\.\d+)?)/, out) do
      [_, version | _] -> version
      _ -> out |> String.trim() |> String.slice(0, 40)
    end
  end

  defp default_mountinfo_read, do: File.read("/proc/self/mountinfo")

  defp default_writable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} -> access in [:read_write, :write]
      _ -> false
    end
  end

  defp default_containerized?, do: File.exists?("/.dockerenv")

  defp default_euid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.to_integer()
      _ -> -1
    end
  end

  defp default_claude_config_present?(nil), do: false

  defp default_claude_config_present?(home) do
    dir = System.get_env("CLAUDE_CONFIG_DIR") || Path.join(home, ".claude")
    File.dir?(dir)
  end

  # ---------------------------------------------------------------------
  # evaluate/1 — pure
  # ---------------------------------------------------------------------

  @doc "Turn collected facts into a `Report.t()`. No IO."
  @spec evaluate(map()) :: Report.t()
  def evaluate(facts) do
    checks = [
      tool_check(:tool_git, "git", facts),
      tool_check(:tool_claude, "claude", facts),
      specify_check(facts),
      presence_only_tool_check(:tool_python3, "python3", facts),
      presence_only_tool_check(:tool_mise, "mise", facts),
      gh_check(facts),
      credential_agent_check(facts),
      credential_gh_check(facts),
      repo_mounted_check(facts),
      repo_path_identity_check(facts),
      home_path_identity_check(facts),
      run_state_writable_check(facts),
      run_state_durable_check(facts),
      target_pack_check(facts),
      image_identity_check(facts),
      unprivileged_check(facts)
    ]

    Report.build(%{
      checks: checks,
      image: facts.image,
      resolved_versions: resolved_versions(facts),
      run_state_root: facts.run_state_root,
      repo: facts.repo,
      collected_at: facts.collected_at
    })
  end

  defp resolved_versions(facts) do
    Enum.reduce(facts.tools, %{}, fn
      {tool, {:ok, version}}, acc -> Map.put(acc, tool, version)
      {_tool, :error}, acc -> acc
    end)
  end

  defp pinned_version(nil, _tool), do: nil
  defp pinned_version(%ImageInfo{tools: tools}, tool), do: Map.get(tools, tool)

  defp tool_check(id, tool, facts) do
    case Map.fetch!(facts.tools, tool) do
      :error ->
        Check.new(
          id: id,
          category: :tool,
          status: :fail,
          detail: "#{tool} not found on PATH",
          expected: "#{tool} present on PATH",
          observed: "absent",
          fix: "install #{tool}, or use the published image which bundles it"
        )

      {:ok, version} ->
        case pinned_version(facts.image, tool) do
          nil ->
            Check.new(
              id: id,
              category: :tool,
              status: :ok,
              detail: "#{tool} resolved on PATH (#{version})"
            )

          ^version ->
            Check.new(
              id: id,
              category: :tool,
              status: :ok,
              detail: "#{tool} resolved on PATH (#{version})",
              expected: version,
              observed: version
            )

          pin ->
            Check.new(
              id: id,
              category: :tool,
              status: :warn,
              detail: "#{tool} version differs from the image pin",
              expected: pin,
              observed: version,
              fix: "rebuild or pull the image, or accept the drift if intentional"
            )
        end
    end
  end

  defp presence_only_tool_check(id, tool, facts) do
    case Map.fetch!(facts.tools, tool) do
      :error ->
        Check.new(
          id: id,
          category: :tool,
          status: :fail,
          detail: "#{tool} not found on PATH",
          expected: "#{tool} present on PATH",
          observed: "absent",
          fix: "install #{tool}, or use the published image which bundles it"
        )

      {:ok, version} ->
        Check.new(id: id, category: :tool, status: :ok, detail: "#{tool} resolved on PATH (#{version})")
    end
  end

  defp specify_check(facts) do
    case Map.fetch!(facts.tools, "specify") do
      :error ->
        Check.new(
          id: :tool_specify,
          category: :tool,
          status: :fail,
          detail: "specify not found on PATH",
          expected: "specify present on PATH",
          observed: "absent",
          fix:
            "install the Spec Kit CLI (`uv tool install --from git+https://github.com/github/spec-kit.git specify-cli`) or use the published image"
        )

      {:ok, version} ->
        if strip_v(version) == strip_v(facts.speckit_version) do
          Check.new(
            id: :tool_specify,
            category: :tool,
            status: :ok,
            detail: "specify resolved on PATH (#{version})",
            expected: facts.speckit_version,
            observed: version
          )
        else
          Check.new(
            id: :tool_specify,
            category: :tool,
            status: :warn,
            detail: "specify version differs from the pinned Spec Kit tag",
            expected: facts.speckit_version,
            observed: version,
            fix: "reinstall specify at #{facts.speckit_version} (SPECKIT_VERSION)"
          )
        end
    end
  end

  # The pinned tag (`SPECKIT_VERSION`, e.g. "v0.12.11") and `specify
  # --version`'s own self-report ("0.12.11") differ only by the "v" the git
  # ref needs and the CLI doesn't print — compare on the number, not the ref.
  defp strip_v("v" <> rest), do: rest
  defp strip_v(version), do: version

  defp gh_check(facts) do
    case {Map.fetch!(facts.tools, "gh"), facts.pr_workflow?} do
      {:error, true} ->
        Check.new(
          id: :tool_gh,
          category: :tool,
          status: :fail,
          detail: "gh not found on PATH and the PR workflow is enabled",
          expected: "gh present on PATH",
          observed: "absent",
          fix: "install the GitHub CLI, or disable SPECKIT_PR_WORKFLOW"
        )

      {:error, false} ->
        Check.new(
          id: :tool_gh,
          category: :tool,
          status: :warn,
          detail: "gh not found on PATH (PR workflow disabled)",
          expected: "gh present on PATH",
          observed: "absent",
          fix: "install the GitHub CLI if you plan to enable SPECKIT_PR_WORKFLOW"
        )

      {{:ok, version}, _pr_workflow?} ->
        Check.new(id: :tool_gh, category: :tool, status: :ok, detail: "gh resolved on PATH (#{version})")
    end
  end

  defp credential_agent_check(facts) do
    case facts.credential_source do
      :absent ->
        Check.new(
          id: :credential_agent,
          category: :credential,
          status: :fail,
          detail: "no agent credential present (source: absent)",
          expected: "ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN, or a mounted ~/.claude",
          observed: "absent",
          fix:
            "set ANTHROPIC_API_KEY in the env file, or mount ~/.claude read-only at /run/secrets/claude"
        )

      source ->
        Check.new(
          id: :credential_agent,
          category: :credential,
          status: :ok,
          detail: "agent credential present (source: #{source})"
        )
    end
  end

  defp credential_gh_check(facts) do
    case {facts.gh_token_present?, facts.pr_workflow?} do
      {false, true} ->
        Check.new(
          id: :credential_gh,
          category: :credential,
          status: :fail,
          detail: "GH_TOKEN absent and the PR workflow is enabled",
          expected: "GH_TOKEN set",
          observed: "absent",
          fix: "set GH_TOKEN in the env file, or disable SPECKIT_PR_WORKFLOW"
        )

      {false, false} ->
        Check.new(
          id: :credential_gh,
          category: :credential,
          status: :warn,
          detail: "GH_TOKEN absent (PR workflow disabled)",
          expected: "GH_TOKEN set",
          observed: "absent",
          fix: "set GH_TOKEN if you plan to enable SPECKIT_PR_WORKFLOW"
        )

      {true, _pr_workflow?} ->
        Check.new(
          id: :credential_gh,
          category: :credential,
          status: :ok,
          detail: "GH_TOKEN present (source: env)"
        )
    end
  end

  defp repo_mounted_check(facts) do
    cond do
      not facts.repo_path_exists? ->
        Check.new(
          id: :repo_mounted,
          category: :mount,
          status: :fail,
          detail: "#{facts.repo} does not exist",
          expected: "an existing git work tree",
          observed: "missing",
          fix: "mount the target repository at #{facts.repo} (-v \"#{facts.repo}:#{facts.repo}\")"
        )

      not facts.repo_git_worktree? ->
        Check.new(
          id: :repo_mounted,
          category: :mount,
          status: :fail,
          detail: "#{facts.repo} is not a git work tree",
          expected: "a git work tree (.git present)",
          observed: "no .git",
          fix: "mount a prepared git work tree at #{facts.repo}"
        )

      not facts.repo_writable? ->
        Check.new(
          id: :repo_mounted,
          category: :mount,
          status: :fail,
          detail: "#{facts.repo} is not writable",
          expected: "writable by the running user",
          observed: "not writable",
          fix: "check the mount's ownership matches --user"
        )

      true ->
        Check.new(
          id: :repo_mounted,
          category: :mount,
          status: :ok,
          detail: "#{facts.repo} is a writable git work tree"
        )
    end
  end

  defp repo_path_identity_check(facts) do
    case facts.env.host_repo do
      nil ->
        Check.new(
          id: :repo_path_identity,
          category: :path_identity,
          status: :warn,
          detail: "AUTONOMOUS_HOST_REPO not set (non-container run)",
          fix: "set AUTONOMOUS_HOST_REPO to the host path of the -v mount if running containerized"
        )

      host_repo when host_repo == facts.repo ->
        Check.new(
          id: :repo_path_identity,
          category: :path_identity,
          status: :ok,
          detail: "AUTONOMOUS_HOST_REPO matches SPECKIT_REPO",
          expected: facts.repo,
          observed: host_repo
        )

      host_repo ->
        Check.new(
          id: :repo_path_identity,
          category: :path_identity,
          status: :fail,
          detail: "AUTONOMOUS_HOST_REPO does not match SPECKIT_REPO",
          expected: facts.repo,
          observed: host_repo,
          fix:
            "mount the repo at its identical host path (-v \"#{host_repo}:#{host_repo}\") and set SPECKIT_REPO=#{host_repo}"
        )
    end
  end

  defp home_path_identity_check(facts) do
    case facts.env.host_home do
      nil ->
        Check.new(
          id: :home_path_identity,
          category: :path_identity,
          status: :warn,
          detail: "AUTONOMOUS_HOST_HOME not set (non-container run)",
          fix: "set AUTONOMOUS_HOST_HOME to the host $HOME if running containerized"
        )

      host_home when host_home == facts.home_env ->
        Check.new(
          id: :home_path_identity,
          category: :path_identity,
          status: :ok,
          detail: "AUTONOMOUS_HOST_HOME matches $HOME",
          expected: facts.home_env,
          observed: host_home
        )

      host_home ->
        Check.new(
          id: :home_path_identity,
          category: :path_identity,
          status: :fail,
          detail: "AUTONOMOUS_HOST_HOME does not match $HOME",
          expected: facts.home_env,
          observed: host_home,
          fix: "set HOME=#{host_home} to match the operator's host home path"
        )
    end
  end

  defp run_state_writable_check(facts) do
    if facts.run_state_writable? do
      Check.new(
        id: :run_state_writable,
        category: :mount,
        status: :ok,
        detail: "#{facts.run_state_root} is writable"
      )
    else
      Check.new(
        id: :run_state_writable,
        category: :mount,
        status: :fail,
        detail: "#{facts.run_state_root} is not writable",
        expected: "writable by the running user",
        observed: "not writable",
        fix: "check the mount's ownership matches --user"
      )
    end
  end

  defp run_state_durable_check(facts) do
    cond do
      facts.run_state_mount_point? ->
        Check.new(
          id: :run_state_durable,
          category: :mount,
          status: :ok,
          detail: "#{facts.run_state_root} is a durable mount point"
        )

      facts.containerized? ->
        Check.new(
          id: :run_state_durable,
          category: :mount,
          status: :fail,
          detail:
            "#{facts.run_state_root} is not a mount point; run state would be lost when the container exits",
          expected: "a bind mount at the identical host path",
          observed: "not a mount point",
          fix: "add -v \"#{facts.run_state_root}:#{facts.run_state_root}\" to the run command"
        )

      true ->
        Check.new(
          id: :run_state_durable,
          category: :mount,
          status: :warn,
          detail: "#{facts.run_state_root} is not a mount point (expected outside a container)",
          fix: "no action needed for a non-containerized run"
        )
    end
  end

  defp target_pack_check(facts) do
    case facts.target_pack_result do
      :ok ->
        Check.new(
          id: :target_pack,
          category: :target_repo,
          status: :ok,
          detail: "target repo enforcement pack verified"
        )

      {:error, reasons} ->
        Check.new(
          id: :target_pack,
          category: :target_repo,
          status: :fail,
          detail: "target repo is not prepared: #{inspect(reasons)}",
          fix: "run TargetPack.install/2 against the target repo and commit a real constitution"
        )
    end
  end

  defp image_identity_check(facts) do
    cond do
      facts.image != nil ->
        Check.new(
          id: :image_identity,
          category: :runtime,
          status: :ok,
          detail: "image manifest read (#{facts.image.image_ref})"
        )

      facts.containerized? ->
        Check.new(
          id: :image_identity,
          category: :runtime,
          status: :fail,
          detail: "/etc/autonomous/image.json unreadable while containerized",
          fix: "rebuild or pull the image — the manifest is written into every runtime stage"
        )

      true ->
        Check.new(
          id: :image_identity,
          category: :runtime,
          status: :warn,
          detail: "no image manifest (expected outside a container)",
          fix: "no action needed for a non-containerized run"
        )
    end
  end

  defp unprivileged_check(facts) do
    if facts.euid == 0 do
      Check.new(
        id: :unprivileged,
        category: :runtime,
        status: :fail,
        detail: "running as root (uid 0)",
        expected: "a non-zero uid",
        observed: "0",
        fix: "start the container with --user <uid>:<gid>"
      )
    else
      Check.new(
        id: :unprivileged,
        category: :runtime,
        status: :ok,
        detail: "running as uid #{facts.euid}"
      )
    end
  end

  # ---------------------------------------------------------------------
  # persist/2 and run/1
  # ---------------------------------------------------------------------

  @doc """
  Write the pretty-printed report to
  `<run_state_root>/preflight/<iso8601>-<status>.json`, and copy it to
  `<run_state_root>/preflight/latest.json`.
  """
  @spec persist(Report.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def persist(%Report{} = report, run_state_root) do
    dir = Path.join(run_state_root, "preflight")

    with :ok <- File.mkdir_p(dir) do
      json = Report.to_json(report)
      path = Path.join(dir, "#{DateTime.to_iso8601(report.collected_at)}-#{report.status}.json")

      with :ok <- File.write(path, json),
           :ok <- File.write(Path.join(dir, "latest.json"), json) do
        {:ok, path}
      end
    end
  end

  @doc "collect → evaluate → persist. `{:error, report}` iff `report.status == :fail`."
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, Report.t()}
  def run(opts \\ []) do
    facts = collect(opts)
    report = evaluate(facts)
    {:ok, _path} = persist(report, facts.run_state_root)

    case report.status do
      :fail -> {:error, report}
      _ -> {:ok, report}
    end
  end
end
