defmodule Autonomous.AttachmentsPrNoteTest do
  use ExUnit.Case, async: true

  alias Autonomous.{Attachment, Attachments, Feature}

  defp feature(attachments, spec_number \\ 12) do
    %Feature{
      id: "001",
      number: 1,
      slug: "checkout",
      path: "/p.md",
      spec_number: spec_number,
      attachments: attachments
    }
  end

  test "empty manifest renders nothing" do
    assert Attachments.pr_note(feature([])) == ""
  end

  test "lists code-span paths with type and size, stored names only" do
    a = %Attachment{
      original_name: "evil name.png",
      stored_name: "evil-name.png",
      type: :png,
      media_type: "image/png",
      size: 1_200_000,
      sha256: "x"
    }

    note = Attachments.pr_note(feature([a]))
    assert note =~ "## Attachments"
    assert note =~ "- `specs/012-checkout/attachments/evil-name.png` (image/png, 1.2 MB)"
    refute note =~ "evil name"
  end

  test "path follows the allocated spec number" do
    a = %Attachment{
      original_name: "a.pdf",
      stored_name: "a.pdf",
      type: :pdf,
      media_type: "application/pdf",
      size: 5,
      sha256: "x"
    }

    assert Attachments.pr_note(feature([a], 7)) =~ "specs/007-checkout/"
  end
end
