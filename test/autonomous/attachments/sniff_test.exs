defmodule Autonomous.Attachments.SniffTest do
  use ExUnit.Case, async: true

  alias Autonomous.AttachmentFixtures, as: Fx
  alias Autonomous.Attachments.Sniff

  test "each binary type is detected by content" do
    assert Sniff.detect("a.png", Fx.png()) == {:ok, :png}
    assert Sniff.detect("a.jpg", Fx.jpeg()) == {:ok, :jpeg}
    assert Sniff.detect("a.gif", Fx.gif()) == {:ok, :gif}
    assert Sniff.detect("a.webp", Fx.webp()) == {:ok, :webp}
    assert Sniff.detect("a.pdf", Fx.pdf()) == {:ok, :pdf}
  end

  test "content wins over the extension" do
    assert Sniff.detect("renamed.txt", Fx.png()) == {:ok, :png}
    assert Sniff.detect("none", Fx.pdf()) == {:ok, :pdf}
  end

  test "trailing padding is tolerated for jpeg and gif" do
    assert Sniff.detect("a.jpg", Fx.jpeg() <> <<0, 0, 0>>) == {:ok, :jpeg}
    assert Sniff.detect("a.gif", Fx.gif() <> <<0, 0>>) == {:ok, :gif}
  end

  test "a truncated file with a signature is corrupt" do
    for {n, bytes} <- [
          png: Fx.png(),
          jpeg: Fx.jpeg(),
          gif: Fx.gif(),
          webp: Fx.webp(),
          pdf: Fx.pdf()
        ] do
      cut = binary_part(bytes, 0, byte_size(bytes) - 6)
      assert Sniff.detect("f.#{n}", cut) == {:error, :corrupt}, "#{n}"
    end
  end

  test "png without IHDR first is corrupt" do
    sig = binary_part(Fx.png(), 0, 8)

    assert Sniff.detect("a.png", sig <> <<0, 0, 0, 13, "XXXX", 0::size(200)>>) ==
             {:error, :corrupt}
  end

  test "image or pdf extension without a signature is a content mismatch" do
    for ext <- ~w(png jpg jpeg gif webp pdf) do
      assert Sniff.detect("note.#{ext}", "just text") == {:error, :content_mismatch}
    end
  end

  test "text types need UTF-8 and no NUL" do
    assert Sniff.detect("a.md", "# hi") == {:ok, :markdown}
    assert Sniff.detect("a.markdown", "# hi") == {:ok, :markdown}
    assert Sniff.detect("a.txt", "héllo") == {:ok, :text}
    assert Sniff.detect("a.csv", "a,b\n1,2") == {:ok, :csv}
    assert Sniff.detect("a.JSON", "not even json") == {:ok, :json}
    assert Sniff.detect("a.txt", <<"ab", 0, "cd">>) == {:error, :not_text}
    assert Sniff.detect("a.txt", <<0xFF, 0xFE, 0x41>>) == {:error, :not_text}
  end

  test "empty is checked first, unknown extensions are unsupported" do
    assert Sniff.detect("a.png", <<>>) == {:error, :empty}
    assert Sniff.detect("a.mp3", "ID3....") == {:error, :unsupported_type}
    assert Sniff.detect("noext", "text") == {:error, :unsupported_type}
  end
end
