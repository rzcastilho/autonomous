defmodule Autonomous.Web.TranscriptMarkup do
  @moduledoc """
  Pure, in-tree renderer for the markup a model writes into a transcript
  (033, research R4, data-model §6). Supports exactly: ATX headings, `**strong**`,
  `*em*`/`_em_`, inline code, fenced code blocks, and ordered/unordered lists
  nested by indentation.

  Safety is by construction: every text run goes through
  `Phoenix.HTML.html_escape/1` *before* any tag is emitted, and the only tags
  in the output are the renderer's own (`h1–h6 p ul ol li pre code strong em`),
  so embedded HTML is inert. An unclosed fence runs to the end of the document
  and an unmatched inline delimiter is literal text — content is never dropped
  (a fence's info string is kept as the `data-lang` attribute, not as text).

  Total: `render/1` accepts any binary (invalid UTF-8 is scrubbed first).
  """

  # Bound on how far an inline delimiter searches for its closer, so a line of
  # unmatched delimiters stays linear instead of quadratic.
  @closer_window 1024

  @ordered_re ~r/^\d+[.)]\s+(.*)$/
  @heading_re ~r/^(\#{1,6})\s+(.*)$/

  @spec render(binary()) :: Phoenix.HTML.safe()
  def render(body) when is_binary(body) do
    body
    |> scrub()
    |> String.split("\n")
    |> blocks()
    |> Enum.map(&block_html/1)
    |> then(&{:safe, &1})
  end

  defp scrub(body), do: if(String.valid?(body), do: body, else: String.replace_invalid(body))

  # ---- block pass ---------------------------------------------------------

  # Classify each line once, so no line is regex-tested twice.
  defp classify(line) do
    {indent, trimmed} = split_indent(line, 0)

    cond do
      trimmed == "" -> :blank
      String.starts_with?(trimmed, "```") -> {:fence, trimmed}
      String.starts_with?(trimmed, "#") -> heading(line, trimmed)
      true -> item(indent, trimmed) || {:text, indent}
    end
  end

  defp split_indent(<<c, rest::binary>>, n) when c in [?\s, ?\t, ?\r],
    do: split_indent(rest, n + 1)

  defp split_indent(rest, n), do: {n, String.trim_trailing(rest)}

  defp heading(line, trimmed) do
    case Regex.run(@heading_re, trimmed) do
      [_, hashes, text] when line != "" -> {:heading, byte_size(hashes), String.trim(text)}
      _ -> {:text, 0}
    end
  end

  defp item(indent, <<m, ?\s, rest::binary>>) when m in [?-, ?*, ?+],
    do: {:item, indent, false, String.trim(rest)}

  defp item(indent, <<c, _::binary>> = trimmed) when c in ?0..?9 do
    case Regex.run(@ordered_re, trimmed) do
      [_, text] -> {:item, indent, true, String.trim(text)}
      _ -> nil
    end
  end

  defp item(_indent, _trimmed), do: nil

  defp blocks(lines), do: lines |> Enum.map(&{&1, classify(&1)}) |> blocks([]) |> merge_lists()

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([{_line, :blank} | rest], acc), do: blocks(rest, acc)

  defp blocks([{_line, {:fence, opener}} | rest], acc) do
    {body, rest} = take_fence(rest, [])
    lang = opener |> String.trim_leading("`") |> String.trim()
    blocks(rest, [{:fence, lang, body} | acc])
  end

  defp blocks([{_line, {:heading, level, text}} | rest], acc),
    do: blocks(rest, [{:heading, level, text} | acc])

  defp blocks([{_line, {:item, indent, ordered?, text}} | rest], acc) do
    {text, rest} = take_continuation(rest, indent, text)
    blocks(rest, [{:item, indent, ordered?, text} | acc])
  end

  defp blocks([{line, {:text, _}} | rest], acc) do
    {lines, rest} = take_paragraph(rest, [line])
    blocks(rest, [{:para, lines} | acc])
  end

  defp take_fence([], acc), do: {Enum.reverse(acc), []}

  defp take_fence([{line, kind} | rest], acc) do
    case kind do
      {:fence, _} -> {Enum.reverse(acc), rest}
      _ -> take_fence(rest, [line | acc])
    end
  end

  # A paragraph ends at a blank line or at the start of any other block.
  defp take_paragraph([{line, {:text, _}} | rest], acc), do: take_paragraph(rest, [line | acc])
  defp take_paragraph(rest, acc), do: {Enum.reverse(acc), rest}

  # An indented plain-text line directly under a list item continues that item.
  defp take_continuation([{line, {:text, n}} | rest], indent, text) when n > indent,
    do: take_continuation(rest, indent, text <> "\n" <> String.trim(line))

  defp take_continuation(rest, _indent, text), do: {text, rest}

  # Consecutive `{:item, ...}` blocks become one `{:list, items}` block. Input is
  # in document order; the fold builds each list reversed, so fix it per list.
  defp merge_lists(blocks) do
    blocks
    |> Enum.reduce([], fn
      {:item, _, _, _} = item, [{:list, items} | acc] -> [{:list, [item | items]} | acc]
      {:item, _, _, _} = item, acc -> [{:list, [item]} | acc]
      other, acc -> [other | acc]
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:list, items} -> {:list, Enum.reverse(items)}
      other -> other
    end)
  end

  # ---- html ---------------------------------------------------------------

  defp block_html({:heading, level, text}),
    do: ["<h", Integer.to_string(level), ">", inline(text), "</h", Integer.to_string(level), ">"]

  defp block_html({:para, lines}), do: ["<p>", Enum.map_join(lines, "\n", &inline_bin/1), "</p>"]

  defp block_html({:fence, lang, body}) do
    attr = if lang == "", do: "", else: [" data-lang=\"", escape(lang), "\""]
    ["<pre><code", attr, ">", escape(Enum.join(body, "\n")), "</code></pre>"]
  end

  defp block_html({:list, items}), do: list_chain(items)

  # An odd indent step can leave items a level's loop didn't take; render them
  # as a following list rather than dropping them.
  defp list_chain([]), do: []

  defp list_chain(items) do
    {html, rest} = list_html(items, 0)
    [html | list_chain(rest)]
  end

  # Renders the items at the first item's indent as one list; deeper items nest
  # under the preceding one. Returns `{iodata, remaining_items}`.
  defp list_html([{:item, base, ordered?, _} | _] = items, floor) do
    tag = if ordered?, do: "ol", else: "ul"
    {lis, rest} = list_items(items, base, floor, [])
    {["<", tag, ">", lis, "</", tag, ">"], rest}
  end

  # `floor` keeps a nested list from swallowing a shallower sibling of its parent.
  defp list_items([{:item, i, _ordered?, text} | rest], base, floor, acc)
       when i <= base and i >= floor do
    {children, rest} = nested(rest, base)
    list_items(rest, base, floor, [["<li>", inline(text), children, "</li>"] | acc])
  end

  defp list_items(rest, _base, _floor, acc), do: {Enum.reverse(acc), rest}

  defp nested([{:item, i, _, _} | _] = items, base) when i > base, do: list_html(items, base + 1)
  defp nested(items, _base), do: {[], items}

  # ---- inline pass --------------------------------------------------------

  defp inline_bin(text), do: text |> inline() |> IO.iodata_to_binary()

  defp inline(text), do: text |> do_inline([]) |> Enum.reverse()

  defp do_inline("", acc), do: acc

  defp do_inline(<<"`", rest::binary>> = text, acc) do
    case close(rest, "`") do
      {inner, after_close} when inner != "" ->
        do_inline(after_close, [["<code>", escape(inner), "</code>"] | acc])

      _ ->
        literal(text, acc)
    end
  end

  defp do_inline(<<"**", rest::binary>> = text, acc) do
    case close(rest, "**") do
      {inner, after_close} when inner != "" ->
        do_inline(after_close, [["<strong>", inline(inner), "</strong>"] | acc])

      _ ->
        literal(text, acc)
    end
  end

  defp do_inline(<<d, rest::binary>> = text, acc) when d in [?*, ?_] do
    delim = <<d>>

    with true <- emphasis_open?(rest, acc, d),
         {inner, after_close} when inner != "" <- close(rest, delim),
         true <- emphasis_close?(inner, after_close, d) do
      do_inline(after_close, [["<em>", inline(inner), "</em>"] | acc])
    else
      _ -> literal(text, acc)
    end
  end

  defp do_inline(text, acc) do
    {plain, rest} = take_plain(text)
    do_inline(rest, [escape(plain) | acc])
  end

  # Emits the first byte-character of `text` as literal text, then continues.
  defp literal(text, acc) do
    {char, rest} = String.split_at(text, 1)
    do_inline(rest, [escape(char) | acc])
  end

  # Plain text up to the next inline delimiter, at least one byte. A byte scan,
  # not `:binary.match/2` with a pattern list, which rebuilds its search
  # automaton on every call.
  defp take_plain(<<_first, rest::binary>> = text) do
    n = 1 + plain_len(rest, 0)
    {binary_part(text, 0, n), binary_part(text, n, byte_size(text) - n)}
  end

  defp plain_len(<<c, _::binary>>, n) when c in [?`, ?*, ?_], do: n
  defp plain_len(<<_, rest::binary>>, n), do: plain_len(rest, n + 1)
  defp plain_len(<<>>, n), do: n

  # Find `delim` within the window; returns `{inner, after_delim}` or `:error`.
  defp close(rest, delim) do
    window = min(byte_size(rest), @closer_window)

    case :binary.match(rest, delim, scope: {0, window}) do
      {pos, len} ->
        {binary_part(rest, 0, pos), binary_part(rest, pos + len, byte_size(rest) - pos - len)}

      :nomatch ->
        :error
    end
  end

  # `*em*`/`_em_` open only before a non-space; `_` additionally never opens
  # inside a word (`snake_case` stays literal).
  defp emphasis_open?(<<c::utf8, _::binary>>, acc, d) do
    not whitespace?(c) and (d == ?* or not word_before?(acc))
  end

  defp emphasis_open?(_rest, _acc, _d), do: false

  defp emphasis_close?(inner, after_close, d) do
    last = inner |> String.last() |> String.to_charlist() |> List.first()

    not whitespace?(last) and (d == ?* or not word_start?(after_close))
  end

  defp whitespace?(c), do: c in [?\s, ?\t, ?\n, ?\r]

  defp word_start?(<<c::utf8, _::binary>>), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9
  defp word_start?(_), do: false

  defp word_before?([prev | _]) do
    case prev |> IO.iodata_to_binary() |> String.last() do
      nil -> false
      ch -> ch =~ ~r/^[[:alnum:]]$/u
    end
  end

  defp word_before?([]), do: false

  defp escape(text), do: Phoenix.HTML.Engine.html_escape(text)
end
