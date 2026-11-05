defmodule Autonomous.Web.AttachmentFormTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.AttachmentForm

  @limits %{max_files: 3, max_file_bytes: 100, max_total_bytes: 250}

  defp entry(ref, name, size, errors \\ []),
    do: %{ref: ref, name: name, size: size, errors: errors}

  test "valid entries are all kept, in order" do
    r = AttachmentForm.triage([entry("0", "a.png", 10), entry("1", "b.pdf", 20)], @limits)
    assert r == %{keep: ["0", "1"], cancel: [], refusals: []}
  end

  test "LiveView's own errors become named refusals" do
    r =
      AttachmentForm.triage(
        [
          entry("0", "big.png", 150, [:too_large]),
          entry("1", "x.bin", 5, [:not_accepted]),
          entry("2", "y.png", 5, [:too_many_files]),
          entry("3", "z.png", 5, [:external_client_failure])
        ],
        @limits
      )

    assert r.cancel == ["0", "1", "2", "3"]

    assert r.refusals == [
             %{file: "big.png", reason: {:too_large, 150, 100}},
             %{file: "x.bin", reason: :unsupported_type},
             %{file: "y.png", reason: {:too_many_files, 3}},
             %{file: "z.png", reason: :unreadable}
           ]
  end

  test "an empty file is refused" do
    assert %{cancel: ["0"], refusals: [%{file: "e.txt", reason: :empty}]} =
             AttachmentForm.triage([entry("0", "e.txt", 0)], @limits)
  end

  test "the file past the count limit is refused by name" do
    entries = for i <- 0..3, do: entry("#{i}", "f#{i}.txt", 1)
    r = AttachmentForm.triage(entries, @limits)
    assert r.keep == ["0", "1", "2"]
    assert r.refusals == [%{file: "f3.txt", reason: {:too_many_files, 3}}]
  end

  test "the file that pushes the running total over is refused, later small ones still fit" do
    r =
      AttachmentForm.triage(
        [entry("0", "a", 100), entry("1", "b", 100), entry("2", "c", 100), entry("3", "d", 40)],
        %{@limits | max_files: 10}
      )

    assert r.keep == ["0", "1", "3"]
    assert r.refusals == [%{file: "c", reason: {:total_too_large, 300, 250}}]
  end

  test "a refused entry does not count against the running totals" do
    r =
      AttachmentForm.triage(
        [entry("0", "bad", 90, [:not_accepted]), entry("1", "a", 100), entry("2", "b", 100)],
        @limits
      )

    assert r.keep == ["1", "2"]
  end

  test "re-triaging the survivors changes nothing" do
    entries = for i <- 0..4, do: entry("#{i}", "f#{i}", 60)
    first = AttachmentForm.triage(entries, @limits)
    survivors = Enum.filter(entries, &(&1.ref in first.keep))
    assert %{cancel: [], refusals: []} = AttachmentForm.triage(survivors, @limits)
  end
end
