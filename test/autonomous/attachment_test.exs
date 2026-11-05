defmodule Autonomous.AttachmentTest do
  use ExUnit.Case, async: true

  alias Autonomous.{Attachment, Feature}

  defp name(original, type \\ :png), do: Attachment.stored_name(original, type)

  describe "stored_name/2" do
    test "plain names keep their stem and take the detected extension" do
      assert name("mockup.png") == "mockup.png"
      assert name("photo.jpeg", :jpeg) == "photo.jpg"
      assert name("scan", :pdf) == "scan.pdf"
      assert name("notes.txt", :markdown) == "notes.md"
      assert name("README.MARKDOWN", :markdown) == "README.markdown"
      assert name("Data.CSV", :csv) == "Data.csv"
    end

    test "path traversal and both separators are cut to the last segment" do
      assert name("../../x.png") == "x.png"
      assert name("a/b/c.png") == "c.png"
      assert name(~S(C:\Users\me\evil.png)) == "evil.png"
      assert name("..") == "attachment.png"
    end

    test "unsafe runs become one dash, leading dots and dashes go, double dots collapse" do
      assert name("my  mock up (v2).png") == "my-mock-up-v2-.png"
      assert name(".hidden.png") == "hidden.png"
      assert name("--x.png") == "x.png"
      assert name("a..b...c.png") == "a.b.c.png"
      assert name("ação.png") == "a-o.png"
    end

    test "empty stem becomes attachment, long stems are capped at 80 bytes" do
      assert name("...png") == "attachment.png"
      assert name("!!!.png") == "attachment.png"
      assert name(".png") == "attachment.png"
      long = String.duplicate("a", 200) <> ".png"
      assert byte_size(name(long)) == 80 + 4
    end

    test "unknown trailing extension is kept as part of the stem" do
      assert name("archive.tar", :png) == "archive.tar.png"
    end
  end

  describe "stored_names/1" do
    test "case-insensitive collisions get -2, -3 in input order" do
      assert Attachment.stored_names([
               {"Shot.png", :png},
               {"shot.png", :png},
               {"SHOT.PNG", :png},
               {"other.png", :png}
             ]) == ["Shot.png", "shot-2.png", "SHOT-3.png", "other.png"]
    end

    test "different detected extensions do not collide" do
      assert Attachment.stored_names([{"a.png", :png}, {"a.pdf", :pdf}]) == ["a.png", "a.pdf"]
    end
  end

  describe "location/2 and directory/1" do
    test "derives from spec_number and slug, never stored" do
      f = %Feature{id: "001", number: 1, slug: "checkout", path: "p", spec_number: 12}

      a = %Attachment{
        original_name: "x",
        stored_name: "m.png",
        type: :png,
        media_type: "image/png",
        size: 1,
        sha256: "x"
      }

      assert Attachment.location(f, a) == "specs/012-checkout/attachments/m.png"
      assert Attachment.directory(f) == "specs/012-checkout/attachments"
    end

    test "falls back to the feature id when no spec number is allocated" do
      f = %Feature{id: "003", number: 3, slug: "s", path: "p"}
      assert Attachment.directory(f) == "specs/003-s/attachments"
    end
  end

  test "records round-trip, nil restores to []" do
    a = %Attachment{
      original_name: "x",
      stored_name: "m.png",
      type: :png,
      media_type: "image/png",
      size: 1,
      sha256: "x"
    }

    assert Attachment.from_records([Attachment.to_record(a)]) == [a]
    assert Attachment.from_records(nil) == []
  end

  describe "media_type/1" do
    test "every type maps to its media type" do
      expected = %{
        png: "image/png",
        jpeg: "image/jpeg",
        gif: "image/gif",
        webp: "image/webp",
        pdf: "application/pdf",
        markdown: "text/markdown",
        text: "text/plain",
        csv: "text/csv",
        json: "application/json"
      }

      for {type, mt} <- expected, do: assert(Attachment.media_type(type) == mt)
    end
  end

  describe "format_size/1" do
    test "bytes, KB and MB with one decimal" do
      assert Attachment.format_size(512) == "512 B"
      assert Attachment.format_size(1_200) == "1.2 KB"
      assert Attachment.format_size(3_400_000) == "3.4 MB"
    end
  end

  describe "from_records/1" do
    test "keeps structs and rebuilds string-free maps" do
      a = %Attachment{
        original_name: "a.png",
        stored_name: "a.png",
        type: :png,
        media_type: "image/png",
        size: 3,
        sha256: "00"
      }

      assert Attachment.from_records([a, Map.from_struct(a)]) == [a, a]
    end
  end
end
