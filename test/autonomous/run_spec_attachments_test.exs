defmodule Autonomous.RunSpecAttachmentsTest do
  # async: false — swaps the global :jido_claude sdk_module and :autonomous app
  # env (repo/worktree_root) and drives the fixed-name Coordinator.
  use Autonomous.StoreCase, async: false

  alias Autonomous.AttachmentFixtures, as: Fx
  alias Autonomous.SingleSpec

  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, opts) do
      Autonomous.FakeArtifacts.write(prompt, opts)

      text =
        cond do
          String.contains?(prompt, "clarify reviewer") -> "Clarified: no ambiguity remains."
          String.contains?(prompt, "/speckit-analyze") -> ~s({"summary":"clean","findings":[]})
          true -> "Phase completed."
        end

      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{session_id: "s", message: %{"content" => text}},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp base_repo(gitignore \\ nil) do
    repo = Path.join(System.tmp_dir!(), "rsa_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 6}))
    if gitignore, do: File.write!(Path.join(repo, ".gitignore"), gitignore)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "rsa_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp point_config_at(repo, root) do
    prev =
      for k <- [:repo, :worktree_root, :autonomous_root],
          do: {k, Application.get_env(:autonomous, k)}

    Application.put_env(:autonomous, :repo, repo)
    Application.put_env(:autonomous, :worktree_root, root)
    Application.put_env(:autonomous, :autonomous_root, root)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:autonomous, k, v),
          else: Application.delete_env(:autonomous, k)
      end
    end)
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)
    end)

    dir = Path.join(System.tmp_dir!(), "rsa_files_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp put(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  describe "with an injected :runner (manifest only, nothing written)" do
    test "the manifest rides on the feature and reaches the store record", %{dir: dir} do
      me = self()

      runner = fn feature, notify ->
        send(me, {:feature, feature})
        notify.(feature.id, :done, nil)
      end

      {:ok, pid} =
        Autonomous.run_spec("Build the screen in the mockup",
          repo: "/no/such/repo/#{System.unique_integer([:positive])}",
          runner: runner,
          owner: me,
          attachments: [
            put(dir, "mockup.png", Fx.png()),
            {put(dir, "tmp-1", Fx.pdf()), "flow.pdf"}
          ]
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:feature, feature}, 2_000
      assert_receive {:run_complete, _}, 2_000

      assert [
               %{original_name: "mockup.png", stored_name: "mockup.png", type: :png},
               %{original_name: "flow.pdf", stored_name: "flow.pdf", type: :pdf}
             ] = feature.attachments

      {:ok, [%{run_id: run_id} | _]} = Autonomous.run_history(limit: 1)
      {:ok, detail} = Autonomous.run_detail(run_id)

      assert [%{attachments: [%{stored_name: "mockup.png"}, %{stored_name: "flow.pdf"}]}] =
               detail.features
    end

    test "a refusal names every bad file and starts nothing", %{dir: dir} do
      missing = Path.join(dir, "gone.png")
      mp3 = put(dir, "song.mp3", "ID3")

      assert {:error,
              {:attachments,
               [
                 %{file: "gone.png", reason: :not_found},
                 %{file: "song.mp3", reason: :unsupported_type}
               ]}} =
               Autonomous.run_spec("Build it",
                 runner: fn _, _ -> flunk("must not start") end,
                 attachments: [missing, mp3]
               )

      refute Process.whereis(Autonomous.Coordinator)
    end

    test "blank description wins over attachments and reads nothing", %{dir: dir} do
      assert {:error, :empty_description} =
               Autonomous.run_spec("  ", attachments: [Path.join(dir, "nope.png")])
    end

    test "run/1 refuses a direct :attachments option; resume/continue take none" do
      assert {:error, {:unsupported_option, :attachments}} =
               Autonomous.run(attachments: ["x.png"])
    end

    test "a refusal leaves no run record", %{dir: dir} do
      before = Autonomous.run_history(limit: 5)

      assert {:error, {:attachments, [%{file: "gone.png"}]}} =
               Autonomous.run_spec("Build it",
                 runner: fn _, _ -> flunk("must not start") end,
                 attachments: [Path.join(dir, "gone.png")]
               )

      assert Autonomous.run_history(limit: 5) == before
    end

    test "no attachments is the pre-047 behaviour" do
      me = self()

      runner = fn feature, notify ->
        send(me, {:attachments, feature.attachments})
        notify.(feature.id, :done, nil)
      end

      {:ok, pid} =
        Autonomous.run_spec("Plain text only",
          repo: "/no/such/repo/#{System.unique_integer([:positive])}",
          runner: runner,
          owner: me
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:attachments, []}, 2_000
    end
  end

  describe "real worktree" do
    test "attachments are committed before the seed, even when the target ignores them", %{
      dir: dir
    } do
      repo = base_repo("*.png\n")
      root = tmp_root()
      point_config_at(repo, root)
      publisher = fn feature, _base -> {:ok, "https://example/pr/#{feature.id}"} end

      {:ok, pid} =
        Autonomous.run_spec("Build the screen in the mockup",
          owner: self(),
          publisher: publisher,
          attachments: [put(dir, "mockup.png", Fx.png())]
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:run_complete, report}, 30_000
      assert report.done == ["001"]

      slug = SingleSpec.slug("Build the screen in the mockup")
      branch = "feature/001-#{slug}"
      rel = "specs/001-#{slug}/attachments/mockup.png"

      {bytes, 0} = git!(repo, ["show", "#{branch}:#{rel}"])
      assert bytes == Fx.png()

      # a :done feature is squashed into one commit; the file is in it
      {log, 0} = git!(repo, ["log", "--format=%s", "main..#{branch}"])
      assert length(String.split(log, "\n", trim: true)) == 1
    end

    test "a text-only run produces no attachment commit and no attachment directory" do
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)
      publisher = fn feature, _base -> {:ok, "https://example/pr/#{feature.id}"} end

      {:ok, pid} = Autonomous.run_spec("Plain text only", owner: self(), publisher: publisher)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:run_complete, report}, 30_000
      assert report.done == ["001"]

      slug = SingleSpec.slug("Plain text only")
      {log, 0} = git!(repo, ["log", "--format=%s", "main..feature/001-#{slug}"])
      refute log =~ "attachments"
      {tree, 0} = git!(repo, ["ls-tree", "-r", "--name-only", "feature/001-#{slug}"])
      refute tree =~ "attachments/"
    end
  end
end
