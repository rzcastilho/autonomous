defmodule SpeckitOrchestrator.BacklogTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Backlog

  @dir Path.expand("../fixtures/breakdown", __DIR__)
  @duplicate Path.expand("../fixtures/breakdown_duplicate", __DIR__)

  describe "load!/1 over the LedgerLite fixtures" do
    setup do
      %{features: Backlog.load!(@dir)}
    end

    test "parses all seven features, sorted by number, README ignored", %{features: features} do
      assert Enum.map(features, & &1.id) == ~w(001 002 003 004 005 006 007)
      assert Enum.map(features, & &1.number) == Enum.to_list(1..7)
    end

    test "features load as :pending, :backlog, with slug and path", %{features: features} do
      f = Enum.find(features, &(&1.id == "001"))
      assert f.slug == "core-ledger"
      assert f.status == :pending
      assert f.group == :backlog
      assert f.created_at == nil
      assert String.ends_with?(f.path, "001-core-ledger.md")
    end

    test "a fixture's ## Prerequisites section is inert prose (FR-010)", %{features: features} do
      # 003's file declares "## Prerequisites\n\n- 002" — Feature has no
      # prereqs field at all any more, so there is nothing to assert it
      # against beyond confirming the struct carries no such data and the
      # order is unaffected (covered in release_test.exs).
      refute Map.has_key?(Map.from_struct(hd(features)), :prereqs)
    end
  end

  test "load!/1 raises DuplicateNumberError on numerically-equal numbers (differing zero-padding)" do
    assert_raise Backlog.DuplicateNumberError, ~r/2/, fn -> Backlog.load!(@duplicate) end
  end

  test "load!/1 raises ParseError on an unreadable dir" do
    assert_raise Backlog.ParseError, fn -> Backlog.load!(Path.join(@dir, "nope")) end
  end

  # FR-016 confirmation (022): the per-wave numeric-uniqueness guard is scoped
  # to one package's own `load!/1` call — two independent packages that each
  # happen to number a feature "002" are not a conflict, because
  # `Backlog.load!/1` never sees the other package's listing. Ordering has
  # exactly one input, the filename's `NNN`, scoped to the directory scanned.
  test "the same number recurring across independent packages is not a conflict (FR-016)" do
    pkg_a =
      Path.join(System.tmp_dir!(), "speckit_backlog_pkg_a_#{System.unique_integer([:positive])}")

    pkg_b =
      Path.join(System.tmp_dir!(), "speckit_backlog_pkg_b_#{System.unique_integer([:positive])}")

    File.mkdir_p!(pkg_a)
    File.mkdir_p!(pkg_b)
    on_exit(fn -> File.rm_rf!(pkg_a); File.rm_rf!(pkg_b) end)

    File.write!(Path.join(pkg_a, "002-billing.md"), "# 002 — Billing\n")
    File.write!(Path.join(pkg_b, "002-inventory.md"), "# 002 — Inventory\n")

    features_a = Backlog.load!(pkg_a)
    features_b = Backlog.load!(pkg_b)

    assert Enum.map(features_a, & &1.id) == ["002"]
    assert Enum.map(features_b, & &1.id) == ["002"]
    assert hd(features_a).slug == "billing"
    assert hd(features_b).slug == "inventory"
  end

  test "gapped numbering is legal — no error, sorted ascending" do
    tmp =
      Path.join(System.tmp_dir!(), "speckit_backlog_gapped_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(tmp, "020-orphan.md"), "# 020 — Orphan\n")
    File.write!(Path.join(tmp, "001-first.md"), "# 001 — First\n")
    File.write!(Path.join(tmp, "005-fifth.md"), "# 005 — Fifth\n")

    features = Backlog.load!(tmp)

    assert Enum.map(features, & &1.id) == ~w(001 005 020)
    assert Enum.map(features, & &1.number) == [1, 5, 20]
  end
end
