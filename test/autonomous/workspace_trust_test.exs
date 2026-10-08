defmodule Autonomous.WorkspaceTrustTest do
  use ExUnit.Case, async: true

  alias Autonomous.WorkspaceTrust

  @dir Path.expand("../fixtures/cli_stderr", __DIR__)

  defp fixture(name), do: @dir |> Path.join(name) |> File.read!() |> String.trim_trailing()

  describe "parse_line/1" do
    test "permissions.allow with a parsable workspace" do
      assert {:untrusted, %{workspace: "/x/repo", kind: "permissions.allow"}} =
               WorkspaceTrust.parse_line(fixture("allow_untrusted.txt"))
    end

    test "permissions.additionalDirectories" do
      assert {:untrusted, %{workspace: "/x/repo", kind: "permissions.additionalDirectories"}} =
               WorkspaceTrust.parse_line(fixture("additional_dirs_untrusted.txt"))
    end

    test "no working directory has no workspace" do
      assert {:untrusted, %{workspace: nil, kind: "permissions.allow"}} =
               WorkspaceTrust.parse_line(fixture("no_cwd.txt"))
    end

    test "untrusted line without a parsable key still reports untrusted" do
      assert {:untrusted, %{workspace: nil, kind: nil}} =
               WorkspaceTrust.parse_line(fixture("unparsable_untrusted.txt"))
    end

    test "unrelated line" do
      assert :other = WorkspaceTrust.parse_line(fixture("unrelated.txt"))
    end
  end

  describe "observe/1" do
    test "nil for no lines or only unrelated lines" do
      assert WorkspaceTrust.observe([]) == nil
      assert WorkspaceTrust.observe([fixture("unrelated.txt")]) == nil
    end

    test "first non-nil workspace, kinds deduped in first-seen order" do
      lines = [
        fixture("unrelated.txt"),
        fixture("no_cwd.txt"),
        fixture("additional_dirs_untrusted.txt"),
        fixture("allow_untrusted.txt"),
        fixture("unparsable_untrusted.txt")
      ]

      assert %{
               workspace: "/x/repo",
               kinds: ["permissions.allow", "permissions.additionalDirectories"]
             } = WorkspaceTrust.observe(lines)
    end
  end
end
