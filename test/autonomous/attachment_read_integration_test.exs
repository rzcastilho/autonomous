defmodule Autonomous.AttachmentReadIntegrationTest do
  @moduledoc """
  LIVE, opt-in probe for feature 047 (quickstart V7): a session reads a PDF at the
  per-file limit and the base64 comes back, so the transport line limit really was
  exercised. Costs a few cents (haiku). Run with:

      mise exec -- mix test test/autonomous/attachment_read_integration_test.exs --include integration

  The first version of this probe read a text-padded file and passed without ever
  receiving the document block. A 6.4 MB PDF (about 16.3 MiB on one line) ended the
  session silently, which is why the per-file default is 6 MB. This test therefore
  asserts on the tool result, not only on the session status.
  """
  use ExUnit.Case, async: false

  alias Autonomous.{Config, PhaseSession}
  alias Jido.Harness.RunRequest

  @moduletag :integration

  # A structurally valid one-page PDF whose content stream is random bytes, so the
  # file is exactly `size` bytes and does not compress to nothing.
  defp pdf(size) do
    head =
      "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n" <>
        "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" <>
        "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj\n"

    tail = "\nendstream\nendobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
    open = "4 0 obj<</Length "
    mid = ">>\nstream\n"
    # Length digits are fixed width so the total is exact.
    fixed = byte_size(head) + byte_size(open) + 9 + byte_size(mid) + byte_size(tail)
    body = size - fixed
    head <> open <> String.pad_leading(Integer.to_string(body), 9, "0") <> mid <> :crypto.strong_rand_bytes(body) <> tail
  end

  test "a PDF at the per-file limit is read, and its base64 line is delivered" do
    size = Config.attachment_max_file_bytes()
    root = Path.join(System.tmp_dir!(), "att_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    File.write!(Path.join(root, "big.pdf"), pdf(size))
    assert File.stat!(Path.join(root, "big.pdf")).size == size

    request =
      RunRequest.new!(%{
        prompt:
          "Use the Read tool once on big.pdf with no pages argument, then reply with exactly: DONE.",
        cwd: root,
        model: "haiku",
        max_turns: 4,
        permission_mode: :bypass_permissions,
        allowed_tools: ["Read"]
      })

    {:ok, stream} = Jido.Harness.run_request(:claude, request, [])
    result = PhaseSession.reduce(stream, 240_000)

    refute inspect(result) =~ "buffer_overflow"
    assert result.status == :ok, "session ended #{inspect(result.status)}: transport line limit?"

    result_event = Enum.find(result.tool_events, &(&1.kind == :result))
    assert result_event, "Read returned no result: the line never arrived"

    assert inspect(result_event.payload, limit: :infinity, printable_limit: 400) =~ "document",
           "Read did not return a document block (the CLI may have asked for pages=)"
  end
end
