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
