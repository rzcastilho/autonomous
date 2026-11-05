defmodule Autonomous.FeatureRunnerAttachmentsTest do
  use ExUnit.Case, async: true

  alias Autonomous.{Attachment, Attachments, Feature, FeatureRunner, Worktree}

  @bytes "hello attachment"

  setup do
    root = Path.join(System.tmp_dir!(), "att-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    feature = %Feature{
      id: "001",
      number: 1,
      spec_number: 1,
      slug: "x",
      path: "/abs/docs/breakdown/001-x.md",
      attachments: [
        %Attachment{
          original_name: "a.txt",
          stored_name: "a.txt",
          type: :text,
          media_type: "text/plain",
          size: byte_size(@bytes),
          sha256: Attachments.sha256(@bytes)
        }
      ]
    }

    wt = %Worktree{path: root, branch: "feature/001-x", repo: root, feature_id: "001"}
    dir = Path.join(root, Attachment.directory(feature))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), @bytes)
    {:ok, feature: feature, wt: wt, dir: dir}
  end

  test "verify passes for intact files", %{feature: f, wt: wt} do
    assert Attachments.verify(f, wt) == :ok
  end

  test "tampered file fails the run before any session", %{feature: f, wt: wt, dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "changed")

    assert %{status: :failed, reason: {:attachments_changed, ["a.txt"]}} =
             FeatureRunner.run(f, worktree: wt)
  end

  test "missing file fails the run", %{feature: f, wt: wt, dir: dir} do
    File.rm!(Path.join(dir, "a.txt"))

    assert %{status: :failed, reason: {:attachments_changed, ["a.txt"]}} =
             FeatureRunner.run(f, worktree: wt)
  end
end
