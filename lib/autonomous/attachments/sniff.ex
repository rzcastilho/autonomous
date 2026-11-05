defmodule Autonomous.Attachments.Sniff do
  @moduledoc """
  Pure content detection for attachments (feature 047, research R2). Content
  decides the type, the extension only breaks ties for text. Stdlib only.

  A matched signature whose structural check fails is `:corrupt`; an image or
  PDF extension with no signature is `:content_mismatch`; a text extension
  needs valid UTF-8 and no NUL byte (`:not_text`); anything else is
  `:unsupported_type`. Empty is `:empty`, checked first.
  """

  alias Autonomous.Attachment

  @type reason :: :empty | :corrupt | :content_mismatch | :not_text | :unsupported_type

  @binary_exts ~w(.png .jpg .jpeg .gif .webp .pdf)
  @text_types %{
    ".md" => :markdown,
    ".markdown" => :markdown,
    ".txt" => :text,
    ".csv" => :csv,
    ".json" => :json
  }

  @png_sig <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  @doc "Detect the attachment type of `bytes`, using `name` only for its extension."
  @spec detect(String.t(), binary()) :: {:ok, Attachment.type()} | {:error, reason()}
  def detect(_name, <<>>), do: {:error, :empty}

  def detect(name, bytes) when is_binary(bytes) do
    case signature(bytes) do
      {:ok, type} -> {:ok, type}
      {:corrupt, _type} -> {:error, :corrupt}
      :none -> by_extension(name |> Path.extname() |> String.downcase(), bytes)
    end
  end

  defp by_extension(ext, bytes) do
    cond do
      ext in @binary_exts -> {:error, :content_mismatch}
      Map.has_key?(@text_types, ext) -> text(Map.fetch!(@text_types, ext), bytes)
      true -> {:error, :unsupported_type}
    end
  end

  defp text(type, bytes) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
      do: {:ok, type},
      else: {:error, :not_text}
  end

  # -- signatures ------------------------------------------------------------

  defp signature(<<@png_sig, rest::binary>> = bytes), do: check(:png, png_ok?(rest, bytes))
  defp signature(<<0xFF, 0xD8, 0xFF, _::binary>> = bytes), do: check(:jpeg, jpeg_ok?(bytes))

  defp signature(<<"GIF8", v, "a", _::binary>> = bytes) when v in [?7, ?9],
    do: check(:gif, gif_ok?(bytes))

  defp signature(<<"RIFF", size::little-32, "WEBP", _::binary>> = bytes),
    do: check(:webp, size + 8 == byte_size(bytes))

  defp signature(<<"%PDF-", _::binary>> = bytes), do: check(:pdf, pdf_ok?(bytes))
  defp signature(_), do: :none

  defp check(type, true), do: {:ok, type}
  defp check(type, false), do: {:corrupt, type}

  defp png_ok?(<<_len::32, "IHDR", _::binary>>, bytes) do
    size = byte_size(bytes)
    size >= 33 and binary_part(bytes, size - 12, 8) == <<0, 0, 0, 0, "IEND">>
  end

  defp png_ok?(_, _), do: false

  defp jpeg_ok?(bytes), do: :binary.match(tail(bytes, 1024), <<0xFF, 0xD9>>) != :nomatch

  defp gif_ok?(bytes) do
    trimmed = trim_trailing_zeros(bytes)
    trimmed != <<>> and :binary.last(trimmed) == 0x3B
  end

  defp pdf_ok?(bytes), do: :binary.match(tail(bytes, 1024), "%%EOF") != :nomatch

  defp tail(bytes, n) do
    size = byte_size(bytes)
    binary_part(bytes, max(size - n, 0), min(size, n))
  end

  defp trim_trailing_zeros(bytes) do
    size = byte_size(bytes)

    if size > 0 and :binary.last(bytes) == 0,
      do: trim_trailing_zeros(binary_part(bytes, 0, size - 1)),
      else: bytes
  end
end
