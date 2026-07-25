defmodule SpeckitOrchestrator.PreflightTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Container.Env
  alias SpeckitOrchestrator.ImageInfo
  alias SpeckitOrchestrator.Preflight
  alias SpeckitOrchestrator.Preflight.Report

  # ---- fixtures ------------------------------------------------------------

  defp image_fixture do
    %ImageInfo{
      source_revision: "abc123",
      orchestrator_version: "0.1.0",
      image_ref: "ghcr.io/rzcastilho/autonomous:v0.1.0",
      built_at: ~U[2026-07-24 18:40:00Z],
      tools: %{
        "git" => "2.39.5",
        "gh" => "2.62.0",
        "claude" => "1.2.3",
        "specify" => "v0.12.11",
        "python3" => "3.11.2",
        "mise" => "2024.1.0"
      },
      elixir: "1.20.2",
      otp: "28",
      base_digests: %{"builder" => "sha256:aaa", "runtime" => "sha256:bbb"}
    }
  end

  defp passing_facts do
    %{
      repo: "/repo",
      run_state_root: "/state",
      collected_at: ~U[2026-07-24 21:00:00Z],
      image: image_fixture(),
      containerized?: true,
      env: %Env{repo: "/repo", host_repo: "/repo", host_home: "/home/alice"},
      tools: %{
        "git" => {:ok, "2.39.5"},
        "gh" => {:ok, "2.62.0"},
        "claude" => {:ok, "1.2.3"},
        "specify" => {:ok, "v0.12.11"},
        "python3" => {:ok, "3.11.2"},
        "mise" => {:ok, "2024.1.0"}
      },
      pr_workflow?: false,
      speckit_version: "v0.12.11",
      gh_token_present?: true,
      credential_source: :env,
      repo_path_exists?: true,
      repo_git_worktree?: true,
      repo_writable?: true,
      home_env: "/home/alice",
      run_state_writable?: true,
      run_state_mount_point?: true,
      target_pack_result: :ok,
      euid: 1000
    }
  end

  # ---- evaluate/1 status derivation -----------------------------------------

  test "evaluate/1 — all checks ok yields :pass" do
    report = Preflight.evaluate(passing_facts())
    assert report.status == :pass
    assert Enum.all?(report.checks, &(&1.status == :ok))
  end

  test "evaluate/1 — one warn (no fail) yields :warn" do
    facts = put_in(passing_facts().tools["specify"], {:ok, "v0.12.10"})
    report = Preflight.evaluate(facts)
    assert report.status == :warn
    assert Enum.find(report.checks, &(&1.id == :tool_specify)).status == :warn
  end

  test "evaluate/1 — any fail yields :fail regardless of warns" do
    facts =
      passing_facts()
      |> put_in([:tools, "specify"], {:ok, "v0.12.10"})
      |> Map.put(:euid, 0)

    report = Preflight.evaluate(facts)
    assert report.status == :fail
  end

  test "evaluate/1 — resolved_versions carries every resolved tool" do
    report = Preflight.evaluate(passing_facts())
    assert report.resolved_versions["git"] == "2.39.5"
    assert report.resolved_versions["specify"] == "v0.12.11"
    refute Map.has_key?(report.resolved_versions, "missing")
  end

  test "evaluate/1 — image nil while containerized fails image_identity" do
    facts = passing_facts() |> Map.put(:image, nil)
    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :image_identity))
    assert check.status == :fail
  end

  test "evaluate/1 — image nil while not containerized warns image_identity" do
    facts = passing_facts() |> Map.put(:image, nil) |> Map.put(:containerized?, false)
    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :image_identity))
    assert check.status == :warn
  end

  test "evaluate/1 — credential_agent fails when source is :absent" do
    facts = passing_facts() |> Map.put(:credential_source, :absent)
    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :credential_agent))
    assert check.status == :fail
    assert check.detail =~ "absent"
    refute check.detail =~ "sk-ant"
  end

  test "evaluate/1 — repo_path_identity warns when assertion vars absent (non-container run)" do
    facts = passing_facts() |> put_in([:env, Access.key!(:host_repo)], nil)
    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :repo_path_identity))
    assert check.status == :warn
  end

  test "evaluate/1 — repo_path_identity fails on mismatch" do
    facts = passing_facts() |> put_in([:env, Access.key!(:host_repo)], "/different/path")
    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :repo_path_identity))
    assert check.status == :fail
    assert check.fix =~ "/different/path"
  end

  test "evaluate/1 — run_state_durable fails when not a mount point in a container" do
    facts = passing_facts() |> Map.put(:run_state_mount_point?, false)
    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :run_state_durable))
    assert check.status == :fail
  end

  test "evaluate/1 — run_state_durable warns when not a mount point outside a container" do
    facts =
      passing_facts()
      |> Map.put(:run_state_mount_point?, false)
      |> Map.put(:containerized?, false)

    report = Preflight.evaluate(facts)
    check = Enum.find(report.checks, &(&1.id == :run_state_durable))
    assert check.status == :warn
  end

  # ---- deterministic ordering -----------------------------------------------

  test "evaluate/1 — checks are sorted by category then id, deterministically" do
    report1 = Preflight.evaluate(passing_facts())
    report2 = Preflight.evaluate(passing_facts())

    ids1 = Enum.map(report1.checks, &{&1.category, &1.id})
    ids2 = Enum.map(report2.checks, &{&1.category, &1.id})

    assert ids1 == ids2
    assert ids1 == Enum.sort_by(ids1, fn {cat, id} -> {to_string(cat), to_string(id)} end)
  end

  # ---- status != :ok ⇒ fix invariant -----------------------------------------

  defp fail_and_warn_variants do
    [
      fn f -> Map.put(f, :euid, 0) end,
      fn f -> Map.put(f, :credential_source, :absent) end,
      fn f -> Map.put(f, :repo_path_exists?, false) end,
      fn f -> Map.put(f, :repo_git_worktree?, false) end,
      fn f -> Map.put(f, :repo_writable?, false) end,
      fn f -> Map.put(f, :run_state_writable?, false) end,
      fn f -> Map.put(f, :run_state_mount_point?, false) end,
      fn f -> put_in(f, [:tools, "git"], :error) end,
      fn f -> put_in(f, [:tools, "gh"], :error) end,
      fn f -> f |> put_in([:tools, "gh"], :error) |> Map.put(:pr_workflow?, true) end,
      fn f -> Map.put(f, :gh_token_present?, false) |> Map.put(:pr_workflow?, true) end,
      fn f -> put_in(f, [:target_pack_result], {:error, [:template_marker_present]}) end,
      fn f -> put_in(f, [:env, Access.key!(:host_repo)], nil) end,
      fn f -> put_in(f, [:env, Access.key!(:host_home)], nil) end,
      fn f -> Map.put(f, :image, nil) end,
      fn f -> f |> Map.put(:image, nil) |> Map.put(:containerized?, false) end
    ]
  end

  test "every check the collector can emit obeys status != :ok ⇒ fix present" do
    for variant <- fail_and_warn_variants() do
      facts = variant.(passing_facts())
      report = Preflight.evaluate(facts)

      for check <- report.checks do
        if check.status != :ok do
          assert is_binary(check.fix) and check.fix != "",
                 "check #{inspect(check.id)} has status #{inspect(check.status)} but no fix"
        end
      end
    end
  end

  # ---- SC-007 completeness matrix (T033) ------------------------------------

  # One row per check id's `:fail` condition, and its `:warn` condition where
  # one exists (contracts/preflight-report.md §3 / data-model.md §2), each a
  # single patch over `passing_facts/0` applied in isolation — proving every
  # emittable message names the specific missing item (`detail`) and the
  # single action that fixes it (`fix`), per FR-033.
  defp sc007_matrix do
    [
      %{id: :tool_git, status: :fail, patch: &put_in(&1, [:tools, "git"], :error),
        detail: "git not found on PATH", fix: "install git"},
      %{id: :tool_git, status: :warn, patch: &put_in(&1, [:tools, "git"], {:ok, "9.9.9"}),
        detail: "git version differs from the image pin", fix: "rebuild or pull the image"},
      %{id: :tool_claude, status: :fail, patch: &put_in(&1, [:tools, "claude"], :error),
        detail: "claude not found on PATH", fix: "install claude"},
      %{id: :tool_claude, status: :warn, patch: &put_in(&1, [:tools, "claude"], {:ok, "9.9.9"}),
        detail: "claude version differs from the image pin", fix: "rebuild or pull the image"},
      %{id: :tool_specify, status: :fail, patch: &put_in(&1, [:tools, "specify"], :error),
        detail: "specify not found on PATH", fix: "install the Spec Kit CLI"},
      %{id: :tool_specify, status: :warn, patch: &put_in(&1, [:tools, "specify"], {:ok, "v0.12.10"}),
        detail: "specify version differs from the pinned Spec Kit tag", fix: "reinstall specify at"},
      %{id: :tool_python3, status: :fail, patch: &put_in(&1, [:tools, "python3"], :error),
        detail: "python3 not found on PATH", fix: "install python3"},
      %{id: :tool_mise, status: :fail, patch: &put_in(&1, [:tools, "mise"], :error),
        detail: "mise not found on PATH", fix: "install mise"},
      %{id: :tool_gh, status: :fail,
        patch: &(&1 |> put_in([:tools, "gh"], :error) |> Map.put(:pr_workflow?, true)),
        detail: "gh not found on PATH and the PR workflow is enabled", fix: "install the GitHub CLI"},
      %{id: :tool_gh, status: :warn,
        patch: &(&1 |> put_in([:tools, "gh"], :error) |> Map.put(:pr_workflow?, false)),
        detail: "gh not found on PATH (PR workflow disabled)", fix: "install the GitHub CLI"},
      %{id: :credential_agent, status: :fail, patch: &Map.put(&1, :credential_source, :absent),
        detail: "no agent credential present", fix: "set ANTHROPIC_API_KEY"},
      %{id: :credential_gh, status: :fail,
        patch: &(&1 |> Map.put(:gh_token_present?, false) |> Map.put(:pr_workflow?, true)),
        detail: "GH_TOKEN absent and the PR workflow is enabled", fix: "set GH_TOKEN"},
      %{id: :credential_gh, status: :warn,
        patch: &(&1 |> Map.put(:gh_token_present?, false) |> Map.put(:pr_workflow?, false)),
        detail: "GH_TOKEN absent (PR workflow disabled)", fix: "set GH_TOKEN"},
      %{id: :repo_mounted, status: :fail, patch: &Map.put(&1, :repo_path_exists?, false),
        detail: "does not exist", fix: "mount the target repository"},
      %{id: :repo_mounted, status: :fail, patch: &Map.put(&1, :repo_git_worktree?, false),
        detail: "is not a git work tree", fix: "mount a prepared git work tree"},
      %{id: :repo_mounted, status: :fail, patch: &Map.put(&1, :repo_writable?, false),
        detail: "is not writable", fix: "check the mount's ownership"},
      %{id: :repo_path_identity, status: :fail,
        patch: &put_in(&1, [:env, Access.key!(:host_repo)], "/different/path"),
        detail: "does not match SPECKIT_REPO", fix: "/different/path"},
      %{id: :repo_path_identity, status: :warn, patch: &put_in(&1, [:env, Access.key!(:host_repo)], nil),
        detail: "not set (non-container run)", fix: "set AUTONOMOUS_HOST_REPO"},
      %{id: :home_path_identity, status: :fail,
        patch: &put_in(&1, [:env, Access.key!(:host_home)], "/different/home"),
        detail: "does not match $HOME", fix: "set HOME="},
      %{id: :home_path_identity, status: :warn, patch: &put_in(&1, [:env, Access.key!(:host_home)], nil),
        detail: "not set (non-container run)", fix: "set AUTONOMOUS_HOST_HOME"},
      %{id: :run_state_writable, status: :fail, patch: &Map.put(&1, :run_state_writable?, false),
        detail: "is not writable", fix: "check the mount's ownership"},
      %{id: :run_state_durable, status: :fail, patch: &Map.put(&1, :run_state_mount_point?, false),
        detail: "not a mount point; run state would be lost", fix: "add -v"},
      %{id: :run_state_durable, status: :warn,
        patch: &(&1 |> Map.put(:run_state_mount_point?, false) |> Map.put(:containerized?, false)),
        detail: "not a mount point (expected outside a container)", fix: "no action needed"},
      %{id: :target_pack, status: :fail,
        patch: &put_in(&1, [:target_pack_result], {:error, [:template_marker_present]}),
        detail: "not prepared", fix: "TargetPack.install/2"},
      %{id: :image_identity, status: :fail, patch: &Map.put(&1, :image, nil),
        detail: "unreadable while containerized", fix: "rebuild or pull the image"},
      %{id: :image_identity, status: :warn,
        patch: &(&1 |> Map.put(:image, nil) |> Map.put(:containerized?, false)),
        detail: "no image manifest (expected outside a container)", fix: "no action needed"},
      %{id: :unprivileged, status: :fail, patch: &Map.put(&1, :euid, 0),
        detail: "running as root", fix: "--user"}
    ]
  end

  test "SC-007 completeness matrix — every check id's :fail (and :warn, where one exists) condition names the missing item and its single fix" do
    for row <- sc007_matrix() do
      facts = row.patch.(passing_facts())
      report = Preflight.evaluate(facts)
      check = Enum.find(report.checks, &(&1.id == row.id))

      assert check, "no check emitted for #{inspect(row.id)}"

      assert check.status == row.status,
             "#{inspect(row.id)}: expected status #{inspect(row.status)}, got #{inspect(check.status)}"

      assert check.detail =~ row.detail,
             "#{inspect(row.id)}: detail #{inspect(check.detail)} does not mention #{inspect(row.detail)}"

      assert is_binary(check.fix) and check.fix =~ row.fix,
             "#{inspect(row.id)}: fix #{inspect(check.fix)} does not mention #{inspect(row.fix)}"
    end
  end

  test "credential checks record source only — never a value, prefix, or length (FR-035)" do
    secret_pattern = ~r/sk-ant-[a-zA-Z0-9-]+|gh[a-z]_[A-Za-z0-9]{10,}/

    variants = [
      passing_facts(),
      passing_facts() |> Map.put(:credential_source, :absent),
      passing_facts() |> Map.put(:credential_source, :mounted_config),
      passing_facts() |> Map.put(:gh_token_present?, false) |> Map.put(:pr_workflow?, true),
      passing_facts() |> Map.put(:gh_token_present?, false) |> Map.put(:pr_workflow?, false)
    ]

    for facts <- variants do
      report = Preflight.evaluate(facts)

      for check <- report.checks, check.category == :credential do
        for field <- [check.detail, check.expected, check.observed, check.fix], is_binary(field) do
          refute field =~ secret_pattern,
                 "#{inspect(check.id)} field #{inspect(field)} looks like a leaked credential"
        end
      end

      credential_agent = Enum.find(report.checks, &(&1.id == :credential_agent))
      assert credential_agent.detail =~ ~r/source: (env|mounted_config|absent)/
    end
  end

  # ---- collect/1 seams ------------------------------------------------------

  test "collect/1 — every seam is independently fakeable with no container or CLI" do
    facts =
      Preflight.collect(
        env: %Env{repo: "/fake/repo", host_repo: "/fake/repo", host_home: "/fake/home"},
        repo: "/fake/repo",
        run_state_root: "/fake/state",
        tool_probe: fn
          "git" -> {:ok, "9.9.9"}
          _ -> :error
        end,
        mountinfo_read: fn -> {:ok, "1 0 0:1 / /fake/state rw - ext4 /dev/x rw"} end,
        writable?: fn _path -> true end,
        target_pack_verify: fn _repo -> :ok end,
        image_read: fn -> {:error, :not_containerized} end,
        containerized?: fn -> true end,
        euid: fn -> 1000 end,
        home_env: "/fake/home",
        claude_config_present?: fn -> true end,
        gh_token_present?: true,
        anthropic_key_present?: false
      )

    assert facts.tools["git"] == {:ok, "9.9.9"}
    assert facts.tools["gh"] == :error
    assert facts.run_state_mount_point? == true
    assert facts.credential_source == :mounted_config
    assert facts.euid == 1000
    assert facts.repo == "/fake/repo"

    report = Preflight.evaluate(facts)
    assert Enum.find(report.checks, &(&1.id == :tool_git)).status == :ok
    assert Enum.find(report.checks, &(&1.id == :tool_gh)).status == :warn
  end

  # ---- persist/2 -------------------------------------------------------------

  test "persist/2 writes pretty-printed JSON and updates latest.json" do
    tmp = Path.join(System.tmp_dir!(), "preflight_persist_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    report = Preflight.evaluate(passing_facts())
    assert {:ok, path} = Preflight.persist(report, tmp)

    assert String.ends_with?(path, "-pass.json")
    assert File.exists?(path)

    contents = File.read!(path)
    assert contents =~ "\n  "
    decoded = Jason.decode!(contents)
    assert decoded["status"] == "pass"

    latest_path = Path.join([tmp, "preflight", "latest.json"])
    assert File.read!(latest_path) == contents
  end

  # ---- FR-034 (T034) ---------------------------------------------------------

  test "persist/2 — a :pass report's persisted JSON carries resolved_versions for every resolved tool" do
    tmp =
      Path.join(System.tmp_dir!(), "preflight_resolved_versions_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp) end)

    facts = passing_facts()
    report = Preflight.evaluate(facts)
    assert {:ok, path} = Preflight.persist(report, tmp)

    decoded = path |> File.read!() |> Jason.decode!()

    for {tool, {:ok, version}} <- facts.tools do
      assert decoded["resolved_versions"][tool] == version,
             "expected resolved_versions[#{inspect(tool)}] == #{inspect(version)}, " <>
               "got #{inspect(decoded["resolved_versions"])}"
    end
  end

  test "persist/2 — identical collected facts persist byte-identical JSON (reproducible, later-drift diagnosable)" do
    report1 = Preflight.evaluate(passing_facts())
    report2 = Preflight.evaluate(passing_facts())

    assert Report.to_json(report1) == Report.to_json(report2)
  end

  test "run/1 — :fail status returns {:error, report} and still persists" do
    tmp = Path.join(System.tmp_dir!(), "preflight_run_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    assert {:error, %Report{status: :fail}} =
             Preflight.run(
               env: %Env{repo: "/no/such/repo"},
               repo: "/no/such/repo",
               run_state_root: tmp,
               tool_probe: fn _ -> {:ok, "1.0.0"} end,
               mountinfo_read: fn -> {:error, :enoent} end,
               writable?: fn _ -> true end,
               target_pack_verify: fn _ -> :ok end,
               image_read: fn -> {:error, :not_containerized} end,
               containerized?: fn -> false end,
               euid: fn -> 1000 end,
               home_env: "/home/alice",
               claude_config_present?: fn -> false end,
               gh_token_present?: false,
               anthropic_key_present?: true
             )

    assert File.exists?(Path.join([tmp, "preflight", "latest.json"]))
  end
end
