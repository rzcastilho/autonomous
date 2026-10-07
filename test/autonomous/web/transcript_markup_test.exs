defmodule Autonomous.Web.TranscriptMarkupTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autonomous.Web.TranscriptMarkup

  defp html(input), do: input |> TranscriptMarkup.render() |> Phoenix.HTML.safe_to_string()

  test "headings h1–h6; seven hashes is a paragraph" do
    assert html("# One") == "<h1>One</h1>"
    assert html("###### Six") == "<h6>Six</h6>"
    assert html("####### Seven") == "<p>####### Seven</p>"
    assert html("#NoSpace") == "<p>#NoSpace</p>"
  end

  test "strong, em with * and _, inline code" do
    assert html("a **b** c") == "<p>a <strong>b</strong> c</p>"
    assert html("a *b* c") == "<p>a <em>b</em> c</p>"
    assert html("a _b_ c") == "<p>a <em>b</em> c</p>"
    assert html("run `mix test` now") == "<p>run <code>mix test</code> now</p>"
  end

  test "inline code content is not interpreted" do
    assert html("`**x**`") == "<p><code>**x**</code></p>"
  end

  test "snake_case and spaced asterisks stay literal" do
    assert html("snake_case_name") == "<p>snake_case_name</p>"
    assert html("2 * 3 * 4") == "<p>2 * 3 * 4</p>"
  end

  test "unmatched delimiter stays literal" do
    assert html("a **b") == "<p>a **b</p>"
    assert html("a `b") == "<p>a `b</p>"
    assert html("a *b") == "<p>a *b</p>"
  end

  test "fenced code, with info string" do
    assert html("```\nx < y\n  z\n```") == "<pre><code>x &lt; y\n  z</code></pre>"
    assert html("```elixir\nx\n```") == "<pre><code data-lang=\"elixir\">x</code></pre>"
  end

  test "unclosed fence runs to end of document" do
    assert html("```\na\n\n# not a heading") == "<pre><code>a\n\n# not a heading</code></pre>"
  end

  test "unordered and ordered lists" do
    assert html("- a\n- b") == "<ul><li>a</li><li>b</li></ul>"
    assert html("1. a\n2) b") == "<ol><li>a</li><li>b</li></ol>"
  end

  test "lists nest by indent" do
    assert html("- a\n  - b\n  - c\n- d") ==
             "<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>"
  end

  test "odd indentation never drops an item" do
    out = html("- a\n    - b\n  - c")
    for t <- ~w(a b c), do: assert(out =~ ">#{t}<")
  end

  test "paragraphs split on blank lines and join continuation lines" do
    assert html("a\nb\n\nc") == "<p>a\nb</p><p>c</p>"
  end

  test "embedded html is escaped" do
    out = html("<script>alert(1)</script>")
    assert out == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"
    refute out =~ "<script"
    assert html("```\n<script>x</script>\n```") =~ "&lt;script&gt;"
    assert html("# <b>x</b>") == "<h1>&lt;b&gt;x&lt;/b&gt;</h1>"
  end

  test "invalid utf-8 does not raise" do
    assert is_binary(html(<<0xFF, 0xFE, "ok", 0xC3>>))
  end

  @allowed ~w(h1 h2 h3 h4 h5 h6 p ul ol li pre code strong em)

  defp tags(out), do: Regex.scan(~r/<\/?([a-z0-9]+)/, out) |> Enum.map(&List.last/1)

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  defp letters(text), do: text |> String.replace(~r/[^\p{L}]/u, "")

  defp token do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 6),
      member_of([
        "**",
        "*",
        "_",
        "`",
        "# ",
        "## ",
        "- ",
        "1. ",
        "  ",
        "    ",
        "\n",
        "\n\n",
        "<",
        ">",
        "&",
        "\"",
        "```\n"
      ])
    ])
  end

  property "render/1 never raises, emits only its own tags, and loses no text" do
    check all(tokens <- list_of(token(), max_length: 40)) do
      input = Enum.join(tokens)
      out = html(input)
      assert Enum.all?(tags(out), &(&1 in @allowed))

      stripped = out |> String.replace(~r/<[^>]*>/, "") |> unescape()
      assert letters(stripped) == letters(input)
    end
  end

  property "arbitrary binaries never raise and emit only allowed tags" do
    check all(bin <- binary()) do
      assert Enum.all?(tags(html(bin)), &(&1 in @allowed))
    end
  end

  test "200 KB renders in under 50 ms" do
    chunk =
      "# Title\n\nSome **bold** and `code` and _em_ text, plain words here.\n- item one\n  - nested\n\n```\ncode line\n```\n"

    input = String.duplicate(chunk, div(200_000, byte_size(chunk)))
    # Best of five after a warm-up: the budget is for the renderer, not for
    # a cold code path or a busy CI neighbour.
    TranscriptMarkup.render(input)

    us =
      1..5
      |> Enum.map(fn _ -> :timer.tc(fn -> TranscriptMarkup.render(input) end) |> elem(0) end)
      |> Enum.min()

    assert us < 50_000
  end
end
