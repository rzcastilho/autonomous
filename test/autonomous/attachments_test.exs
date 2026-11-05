defmodule Autonomous.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Autonomous.AttachmentFixtures, as: Fx
  alias Autonomous.{Attachment, Attachments, Feature, Worktree}

  setup do
    dir = Path.join(System.tmp_dir!(), "att_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp put(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  describe "load/2" do
    test "empty input is an empty manifest" do
      assert Attachments.load([]) == {:ok, {[], []}}
    end

    test "bare path uses the basename, tuple form uses the display name, bytes are untouched",
         %{dir: dir} do
      a = put(dir, "mockup.png", Fx.png())
      b = put(dir, "live_view_upload-abc", Fx.pdf())

      assert {:ok, {[m1, m2], [{"mockup.png", bytes1}, {"flow.pdf", bytes2}]}} =
               Attachments.load([a, {b, "flow.pdf"}])

      assert m1.original_name == "mockup.png"
      assert m1.type == :png and m1.media_type == "image/png"
      assert m1.size == byte_size(Fx.png())
      assert m1.sha256 == Attachments.sha256(Fx.png())
      assert m2.stored_name == "flow.pdf" and m2.type == :pdf
      assert bytes1 == Fx.png() and bytes2 == Fx.pdf()
    end

    test "every refusal is collected in one pass", %{dir: dir} do
      good = put(dir, "ok.png", Fx.png())
      mp3 = put(dir, "song.mp3", "ID3")
      empty = put(dir, "empty.txt", "")
      bad = put(dir, "fake.png", "text")
      trunc = put(dir, "cut.pdf", "%PDF-1.4 no end")

      assert {:error, {:attachments, refusals}} =
               Attachments.load([good, mp3, empty, bad, trunc, Path.join(dir, "missing.png")])

      assert Enum.sort_by(refusals, & &1.file) == [
               %{file: "cut.pdf", reason: :corrupt},
               %{file: "empty.txt", reason: :empty},
               %{file: "fake.png", reason: :content_mismatch},
               %{file: "missing.png", reason: :not_found},
               %{file: "song.mp3", reason: :unsupported_type}
             ]
    end

    test "a directory is unreadable", %{dir: dir} do
      assert {:error, {:attachments, [%{file: "sub", reason: :unreadable}]}} =
               Attachments.load([dir |> Path.join("sub") |> tap(&File.mkdir_p!/1)])
    end

    test "the file past the count limit is refused by name", %{dir: dir} do
      paths = for i <- 1..3, do: put(dir, "f#{i}.txt", "x")

      assert {:error, {:attachments, [%{file: "f3.txt", reason: {:too_many_files, 2}}]}} =
               Attachments.load(paths, max_files: 2)
    end

    test "a file over the per-file limit is refused", %{dir: dir} do
      p = put(dir, "big.txt", String.duplicate("a", 11))

      assert {:error, {:attachments, [%{file: "big.txt", reason: {:too_large, 11, 10}}]}} =
               Attachments.load([p], max_file_bytes: 10)
    end

    test "the file crossing the total limit is named", %{dir: dir} do
      ps = for i <- 1..3, do: put(dir, "f#{i}.txt", String.duplicate("a", 6))

      assert {:error, {:attachments, [%{file: "f2.txt", reason: {:total_too_large, 12, 10}}]}} =
               Attachments.load(ps, max_total_bytes: 10)
    end

    test "colliding names get suffixes", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "a"))
      File.mkdir_p!(Path.join(dir, "b"))
      a = put(dir, "a/shot.png", Fx.png())
      b = put(dir, "b/Shot.png", Fx.jpeg())
      assert {:ok, {[m1, m2], _}} = Attachments.load([a, b])
      assert [m1.stored_name, m2.stored_name] == ["shot.png", "Shot.jpg"]
    end
  end

  describe "commit/3 and verify/2" do
    defp git!(repo, args),
      do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

    defp repo_with_ignore do
      repo = Path.join(System.tmp_dir!(), "att_repo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["config", "user.email", "t@example.com"])
      git!(repo, ["config", "user.name", "Tester"])
      File.mkdir_p!(Path.join(repo, ".specify/memory"))
      File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
      File.mkdir_p!(Path.join(repo, ".claude/skills"))
      File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
      File.write!(Path.join(repo, ".gitignore"), "*.png\n")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "base"])
      on_exit(fn -> File.rm_rf(repo) end)
      repo
    end

    defp setup_wt(manifest) do
      repo = repo_with_ignore()
      root = Path.join(System.tmp_dir!(), "att_root_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)

      feature = %Feature{
        id: "900",
        number: 900,
        slug: "att",
        path: "p",
        spec_number: 12,
        attachments: manifest
      }

      {:ok, wt} = Worktree.create(feature, repo: repo, worktree_root: root)
      {feature, wt}
    end

    setup %{dir: dir} do
      p = put(dir, "mock.png", Fx.png())
      {:ok, {manifest, payloads}} = Attachments.load([p])
      {:ok, manifest: manifest, payloads: payloads}
    end

    test "commits the files even though the target ignores *.png, and they survive restore",
         %{manifest: manifest, payloads: payloads} do
      {feature, wt} = setup_wt(manifest)
      assert :ok = Attachments.commit(feature, wt, payloads)

      rel = Attachment.location(feature, hd(manifest))
      assert rel == "specs/012-att/attachments/mock.png"
      assert File.read!(Path.join(wt.path, rel)) == Fx.png()

      {tracked, 0} = System.cmd("git", ["-C", wt.path, "ls-files", rel])
      assert String.trim(tracked) == rel

      {log, 0} = System.cmd("git", ["-C", wt.path, "log", "-1", "--format=%an|%s"])
      assert String.trim(log) == "autonomous|speckit: 900 attachments (1 files)"

      assert Attachments.verify(feature, wt) == :ok

      File.write!(Path.join(wt.path, "scratch.txt"), "x")
      assert :ok = Worktree.restore(wt)
      assert File.read!(Path.join(wt.path, rel)) == Fx.png()
      assert Attachments.verify(feature, wt) == :ok
    end

    test "tampered or deleted files are reported by stored name",
         %{manifest: manifest, payloads: payloads} do
      {feature, wt} = setup_wt(manifest)
      :ok = Attachments.commit(feature, wt, payloads)
      path = Path.join(wt.path, Attachment.location(feature, hd(manifest)))

      File.write!(path, "tampered")
      assert Attachments.verify(feature, wt) == {:error, {:attachments_changed, ["mock.png"]}}

      File.rm!(path)
      assert Attachments.verify(feature, wt) == {:error, {:attachments_changed, ["mock.png"]}}
    end

    test "empty manifest is a no-op for both" do
      {feature, wt} = setup_wt([])
      assert Attachments.commit(feature, wt, []) == :ok
      assert Attachments.verify(feature, wt) == :ok
      refute File.exists?(Path.join(wt.path, "specs"))
    end
  end
end
