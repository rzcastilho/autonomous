defmodule SpeckitOrchestrator.SingleSpecTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Backlog, Feature, SingleSpec}

  describe "next_id/1" do
    test "\"001\" when no ids are taken" do
      assert SingleSpec.next_id([]) == "001"
    end

    test "one past the highest existing id, zero-padded" do
      assert SingleSpec.next_id(["001", "003"]) == "004"
    end

    test "ignores non-numeric entries rather than crashing" do
      assert SingleSpec.next_id(["001", "not-a-number"]) == "002"
    end

    test "pads past 3 digits without truncating" do
      assert SingleSpec.next_id(["999"]) == "1000"
    end
  end

  describe "slug/1" do
    test "kebab-cases the first tokens of a description" do
      assert SingleSpec.slug("Add a health check endpoint please") == "add-a-health-check-endpoint"
    end

    test "caps at 5 tokens" do
      assert SingleSpec.slug("one two three four five six seven") == "one-two-three-four-five"
    end

    test "truncates to 40 characters" do
      slug = SingleSpec.slug("supercalifragilisticexpialidocious extra long words here")
      assert String.length(slug) <= 40
      refute String.ends_with?(slug, "-")
    end

    test "falls back to \"feature\" when nothing alphanumeric survives" do
      assert SingleSpec.slug("!!! --- ???") == "feature"
    end
  end

  describe "seed_body/2" do
    test "renders a breakdown doc with no prerequisites" do
      body = SingleSpec.seed_body("001", "Add a health check endpoint")

      assert body =~ "# 001 — Add A Health Check"
      assert body =~ "Add a health check endpoint"
      assert body =~ "## Prerequisites"
      assert body =~ "None"
    end

    test "round-trips through Backlog as a single no-prereq feature" do
      dir = Path.join(System.tmp_dir!(), "single_spec_seed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      body = SingleSpec.seed_body("007", "Do the thing")
      File.write!(Path.join(dir, "007-do-the-thing.md"), body)

      [feature] = Backlog.load!(dir)
      assert feature.id == "007"
      assert feature.slug == "do-the-thing"
      assert feature.prereqs == []
    end
  end

  describe "build/3" do
    test "rejects a nil description" do
      assert SingleSpec.build(nil, []) == {:error, :empty_description}
    end

    test "rejects an empty description" do
      assert SingleSpec.build("", []) == {:error, :empty_description}
    end

    test "rejects a whitespace-only description" do
      assert SingleSpec.build("   \n\t  ", []) == {:error, :empty_description}
    end

    test "builds a pending, prereq-free Feature from a valid description" do
      assert {:ok, %Feature{} = feature} = SingleSpec.build("Add a health check endpoint", [])
      assert feature.id == "001"
      assert feature.slug == "add-a-health-check-endpoint"
      assert feature.prereqs == []
      assert feature.status == :pending
      assert feature.path == "docs/breakdown/001-add-a-health-check-endpoint.md"
    end

    test "auto-assigns past already-taken ids" do
      assert {:ok, feature} = SingleSpec.build("Second feature", ["001", "002"])
      assert feature.id == "003"
    end

    test "honors a :breakdown_dir override" do
      assert {:ok, feature} =
               SingleSpec.build("Add a health check endpoint", [], breakdown_dir: "custom/dir")

      assert feature.path == "custom/dir/001-add-a-health-check-endpoint.md"
    end
  end
end
