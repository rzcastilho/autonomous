defmodule Autonomous.AttachmentReadIntegrationTest do
  @moduledoc """
  LIVE, opt-in probe for feature 047 (quickstart V7): a session reads a ~10 MB
  attached PDF and ends normally (no `buffer_overflow`). Run with:

      mise exec -- mix test test/autonomous/attachment_read_integration_test.exs --include integration
  """
  use ExUnit.Case, async: false

  alias Autonomous.PhaseSession
  alias Jido.Harness.RunRequest

  @moduletag :integration

  test "a ~10 MB PDF is read without overflowing the transport line limit" do
    root = Path.join(System.tmp_dir!(), "att_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    pad = :binary.copy("% padding\n", 1_000_000)
    File.write!(Path.join(root, "big.pdf"), "%PDF-1.4\n" <> pad <> "trailer\n<<>>\n%%EOF\n")

    request =
      RunRequest.new!(%{
        prompt: "Use the Read tool once on big.pdf, then say DONE.",
        cwd: root,
        model: "haiku",
        max_turns: 4,
        permission_mode: :bypass_permissions,
        allowed_tools: ["Read"]
      })

    {:ok, stream} = Jido.Harness.run_request(:claude, request, [])
    result = PhaseSession.reduce(stream, 180_000)

    refute inspect(result) =~ "buffer_overflow"
    assert result.status == :ok
  end
end
