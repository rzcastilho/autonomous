defmodule SpeckitOrchestrator.RepoIdentityTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.RepoIdentity

  describe "canonicalize/1 (hermetic)" do
    test "SSH, HTTPS, HTTPS-trailing-slash, and ssh:// forms all canonicalize the same" do
      expected = "github.com/rzcastilho/ledgerlite"

      for url <- [
            "git@github.com:rzcastilho/ledgerlite.git",
            "https://github.com/rzcastilho/ledgerlite.git",
            "https://github.com/rzcastilho/ledgerlite/",
            "ssh://git@github.com/rzcastilho/ledgerlite"
          ] do
        assert {:ok, ^expected} = RepoIdentity.canonicalize(url), "for #{url}"
      end
    end

    test "lower-cases the host but preserves path case" do
      assert {:ok, "github.com/RzCastilho/LedgerLite"} =
               RepoIdentity.canonicalize("https://GitHub.Com/RzCastilho/LedgerLite.git")
    end

    test "different owner canonicalizes to a different string" do
      assert {:ok, a} = RepoIdentity.canonicalize("git@github.com:alice/repo.git")
      assert {:ok, b} = RepoIdentity.canonicalize("git@github.com:bob/repo.git")
      assert a != b
    end

    test "different host canonicalizes to a different string" do
      assert {:ok, a} = RepoIdentity.canonicalize("git@github.com:acme/repo.git")
      assert {:ok, b} = RepoIdentity.canonicalize("git@gitlab.com:acme/repo.git")
      assert a != b
    end

    test "returns :error for input with no recognizable host/path" do
      assert :error = RepoIdentity.canonicalize("not-a-url")
    end
  end

  describe "segment/1 (hermetic)" do
    test "is deterministic for the same canonical input" do
      canonical = "github.com/rzcastilho/ledgerlite"
      assert RepoIdentity.segment(canonical) == RepoIdentity.segment(canonical)
    end

    test "produces a <repo>-<6hex> segment" do
      segment = RepoIdentity.segment("github.com/rzcastilho/ledgerlite")
      assert segment =~ ~r/^ledgerlite-[0-9a-f]{6}$/
    end

    test "same repo name under different owner/host shares the name prefix but differs in hash" do
      a = RepoIdentity.segment("github.com/alice/repo")
      b = RepoIdentity.segment("gitlab.com/bob/repo")

      assert String.starts_with?(a, "repo-")
      assert String.starts_with?(b, "repo-")
      assert a != b
    end
  end

  describe "resolve/1 (integration — real git)" do
    @describetag :integration

    test "returns {:error, :no_origin} for a repo with no origin remote" do
      dir = Path.join(System.tmp_dir!(), "repoid_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {_, 0} = System.cmd("git", ["init", "-q", dir])

      assert {:error, :no_origin} = RepoIdentity.resolve(dir)
    end

    test "resolves a segment from a repo with an origin remote" do
      dir = Path.join(System.tmp_dir!(), "repoid_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {_, 0} = System.cmd("git", ["init", "-q", dir])

      {_, 0} =
        System.cmd("git", [
          "-C",
          dir,
          "remote",
          "add",
          "origin",
          "git@github.com:rzcastilho/ledgerlite.git"
        ])

      assert {:ok, segment} = RepoIdentity.resolve(dir)
      assert segment =~ ~r/^ledgerlite-[0-9a-f]{6}$/
    end
  end
end
