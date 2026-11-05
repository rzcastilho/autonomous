defmodule Autonomous.AttachmentFixtures do
  @moduledoc false
  # Minimal structurally-valid files for attachment tests (feature 047).

  def png do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0::size(13 * 8), 0::32, 0, 0, 0,
      0, "IEND", 0xAE, 0x42, 0x60, 0x82>>
  end

  def jpeg, do: <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0::size(9 * 8), 0xFF, 0xD9>>

  def gif, do: <<"GIF89a", 1, 0, 1, 0, 0, 0, 0, 0x3B>>

  def webp do
    body = <<"WEBP", "VP8 ", 4::little-32, 1, 2, 3, 4>>
    <<"RIFF", byte_size(body)::little-32, body::binary>>
  end

  def pdf, do: "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n"
end
