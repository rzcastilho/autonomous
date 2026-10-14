defmodule Autonomous.ConversationFileTest do
  use ExUnit.Case, async: true

  alias Autonomous.{ConversationEntry, ConversationFile, ConversationIdentity}

  @moduletag :tmp_dir

  defp identity(root),
    do: %ConversationIdentity{
      run_id: "r000001",
      feature_id: "001",
      phase: :clarify,
      ordinal: 1,
      kind: :phase,
      transcript_root: root
    }

  defp entry(seq, kind \\ :assistant_text),
    do: %ConversationEntry{
      seq: seq,
      at: "2026-10-10T00:00:00Z",
      kind: kind,
      body: %{"text" => "t#{seq}"}
    }

  defp write!(root, n) do
    {:ok, h, _} = ConversationFile.open(identity(root), "c-1", "2026-10-10T00:00:00Z")
    for i <- 0..(n - 1), do: {:ok, _} = ConversationFile.append(h, entry(i))
    ConversationFile.close(h)
    h.path
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "open creates 0700 dirs and 0600 file with a header", %{tmp_dir: root} do
    {:ok, h, _} = ConversationFile.open(identity(root), "c-1", "2026-10-10T00:00:00Z")
    ConversationFile.close(h)

    assert h.rel == "conversations/r000001/001/c-1.jsonl"
    assert ConversationFile.resolve(root, h.rel) == h.path
    assert mode(h.path) == 0o600

    for d <- ["conversations", "conversations/r000001", "conversations/r000001/001"],
        do: assert(mode(Path.join(root, d)) == 0o700)

    header = h.path |> File.read!() |> String.split("\n") |> hd() |> Jason.decode!()

    assert %{"format" => "speckit.conversation", "version" => 1, "conversation_id" => "c-1"} =
             header

    assert {:ok, ^header} = ConversationFile.header_of(h.path)
  end

  test "exclusive: a collision is :eexist, never an overwrite", %{tmp_dir: root} do
    {:ok, h, _} = ConversationFile.open(identity(root), "c-1", "x")
    ConversationFile.close(h)
    assert {:error, {:open_failed, :eexist}} = ConversationFile.open(identity(root), "c-1", "x")
  end

  test "open failure is {:open_failed, posix}", %{tmp_dir: root} do
    File.write!(Path.join(root, "conversations"), "i am a file")
    assert {:error, {:open_failed, _}} = ConversationFile.open(identity(root), "c-1", "x")
  end

  test "page/3 pages and reports next_seq / :eof", %{tmp_dir: root} do
    path = write!(root, 5)
    assert {:ok, [%{seq: 0}, %{seq: 1}], 2} = ConversationFile.page(path, 0, 2)
    assert {:ok, [%{seq: 2}, %{seq: 3}], 4} = ConversationFile.page(path, 2, 2)
    assert {:ok, [%{seq: 4}], :eof} = ConversationFile.page(path, 4, 2)
    assert {:ok, [%{seq: 3}, %{seq: 4}], :eof} = ConversationFile.page(path, 3, 2)
    assert {:ok, [], :eof} = ConversationFile.page(path, 9, 2)
  end

  test "entry/2", %{tmp_dir: root} do
    path = write!(root, 3)
    assert {:ok, %{seq: 1, body: %{"text" => "t1"}}} = ConversationFile.entry(path, 1)
    assert {:error, :not_found} = ConversationFile.entry(path, 7)
  end

  test "missing and unreadable", %{tmp_dir: root} do
    assert {:error, :missing} = ConversationFile.page(Path.join(root, "nope.jsonl"), 0, 5)
    assert {:error, {:unreadable, _}} = ConversationFile.page(root, 0, 5)
  end

  test "malformed JSON reports the line, earlier entries still returned", %{tmp_dir: root} do
    path = write!(root, 3)
    File.write!(path, "{not json\n", [:append])

    assert {:error, {:malformed, 5}, [%{seq: 0}, %{seq: 1}, %{seq: 2}]} =
             ConversationFile.page(path, 0, 10)
  end

  test "seq gap is malformed", %{tmp_dir: root} do
    path = write!(root, 2)
    File.write!(path, Jason.encode!(ConversationEntry.encode(entry(5))) <> "\n", [:append])
    assert {:error, {:malformed, 4}, [%{seq: 0}, %{seq: 1}]} = ConversationFile.page(path, 0, 10)
  end

  test "a newer header version is refused by name", %{tmp_dir: root} do
    path = Path.join(root, "v2.jsonl")

    File.write!(
      path,
      Jason.encode!(%{"format" => "speckit.conversation", "version" => 2}) <> "\n"
    )

    assert {:error, {:unsupported_version, 2}} = ConversationFile.page(path, 0, 5)
  end

  test "a garbage header is malformed line 1", %{tmp_dir: root} do
    path = Path.join(root, "bad.jsonl")
    File.write!(path, "hello\n")
    assert {:error, {:malformed, 1}} = ConversationFile.page(path, 0, 5)
  end

  describe "fold/4" do
    defp seqs(path, opts \\ []),
      do: ConversationFile.fold(path, [], fn e, acc -> [e.seq | acc] end, opts)

    test "streams every entry in order", %{tmp_dir: root} do
      path = write!(root, 5)
      assert {:ok, [4, 3, 2, 1, 0]} = seqs(path)
    end

    test "through_seq stops without reading past it", %{tmp_dir: root} do
      path = write!(root, 5)
      assert {:ok, [2, 1, 0]} = seqs(path, through_seq: 2)

      # content after the stop is never decoded, so a partly written line there is harmless
      File.write!(path, "{partial", [:append])
      assert {:ok, [4, 3, 2, 1, 0]} = seqs(path, through_seq: 4)
      assert {:error, {:malformed, 7}} = seqs(path)
    end

    test "errors are tagged", %{tmp_dir: root} do
      assert {:error, :missing} = seqs(Path.join(root, "nope.jsonl"))
      assert {:error, {:unreadable, _}} = seqs(root)

      v2 = Path.join(root, "v2.jsonl")

      File.write!(
        v2,
        Jason.encode!(%{"format" => "speckit.conversation", "version" => 2}) <> "\n"
      )

      assert {:error, {:unsupported_version, 2}} = seqs(v2)

      bad = write!(Path.join(root, "x") |> tap(&File.mkdir_p!/1), 3)
      File.write!(bad, "{not json\n", [:append])
      assert {:error, {:malformed, 5}} = seqs(bad)
      assert {:ok, [2, 1, 0]} = seqs(bad, through_seq: 2)
    end
  end
end
