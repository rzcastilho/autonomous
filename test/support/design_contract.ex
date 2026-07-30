defmodule SpeckitOrchestrator.Web.DesignContract do
  @moduledoc """
  Pure mechanical guard for `docs/design-constitution.md` (constitution 2.2.0
  Principle VII / Operator Surface Design), per
  `specs/020-reconcile-console-design/contracts/design-guard.md`.

  `scan/1` is a pure function of a `%{path => source}` map — no file I/O, no
  network, no shell out (G-1). All I/O is confined to `load/1`. Ships in
  `test/support` only (`mix.exs`'s `elixirc_paths(:test)`), so it adds no
  runtime code and no dependency.

  The rule set is closed (G-4): what it decides is listed in
  `contracts/design-guard.md` §5 "Guard"; everything else is the judgment
  half, recorded in `compliance-inventory.md`.
  """

  defmodule Violation do
    @moduledoc "One mechanically-detected divergence. Always names `path` and `line` (G-2)."
    @enforce_keys [:rule, :path, :line, :excerpt]
    defstruct [:rule, :path, :line, :excerpt]

    @type t :: %__MODULE__{
            rule: atom(),
            path: String.t(),
            line: pos_integer(),
            excerpt: String.t()
          }
  end

  alias __MODULE__.Violation

  # ---- input domain (contracts/design-guard.md §2 — enumerated, not globbed) ----

  @css_path "priv/static/assets/console.css"

  @surfaces [
    @css_path,
    "priv/static/assets/app.js",
    "lib/speckit_orchestrator/web/components/core_components.ex",
    "lib/speckit_orchestrator/web/components/feature_drawer.ex",
    "lib/speckit_orchestrator/web/components/layouts.ex",
    "lib/speckit_orchestrator/web/components/layouts/app.html.heex",
    "lib/speckit_orchestrator/web/components/layouts/root.html.heex",
    "lib/speckit_orchestrator/web/live/mission_control_live.ex",
    "lib/speckit_orchestrator/web/live/pipeline_dag_live.ex",
    "lib/speckit_orchestrator/web/live/trigger_live.ex",
    "lib/speckit_orchestrator/web/live/escalations_live.ex",
    "lib/speckit_orchestrator/web/live/runs_live.ex",
    "lib/speckit_orchestrator/web/live/run_detail_live.ex",
    "lib/speckit_orchestrator/web/live/transcripts_live.ex",
    "lib/speckit_orchestrator/web/live/config_live.ex"
  ]

  @doc "Console surfaces the guard governs, repo-relative (G-6)."
  @spec surfaces() :: [String.t()]
  def surfaces, do: @surfaces

  # `specs/011-.../design-system.md` is not a console surface (data-model.md
  # §4) — it is read separately, only for `:frozen_artifact` (G-1: the
  # "committed content" it's compared against is captured at compile time via
  # `@external_resource`, so the comparison stays a pure `scan/1` equality
  # check rather than a git shell-out).
  @frozen_artifact_path "specs/011-control-plane-ui-redesign/contracts/design-system.md"
  @external_resource Path.expand("../../#{@frozen_artifact_path}", __DIR__)
  @frozen_artifact_content File.read!(Path.expand("../../#{@frozen_artifact_path}", __DIR__))

  @doc "Read `surfaces/0` (plus the frozen-artifact reference) from disk into the `scan/1` input shape."
  @spec load(Path.t()) :: %{String.t() => String.t()}
  def load(root) do
    base = Path.expand(root)
    extra = %{@frozen_artifact_path => File.read!(Path.join(base, @frozen_artifact_path))}

    for path <- @surfaces, into: extra do
      {path, File.read!(Path.join(base, path))}
    end
  end

  # ---- §II — the 24 contract colors, transcribed verbatim from
  # docs/design-constitution.md §II (G-7: a dedicated test asserts this
  # transcription matches the doc's own fenced CSS block). ----

  @contract_colors [
    {"--bg", "#0b0d12"},
    {"--panel", "#0e1016"},
    {"--card", "#12151d"},
    {"--raised", "#161a23"},
    {"--hairline", "#14181f"},
    {"--border-subtle", "#1c212c"},
    {"--border", "#232936"},
    {"--border-strong", "#2a3142"},
    {"--text", "#e6e9f0"},
    {"--text-secondary", "#c3c9d6"},
    {"--text-muted", "#8b93a7"},
    {"--text-faint", "#5a6274"},
    {"--accent", "#7c5cff"},
    {"--accent-light", "#a78bfa"},
    {"--accent-hover", "#c4b5fd"},
    {"--accent-deep", "#5a3fe0"},
    {"--accent-shadow", "#2a2350"},
    {"--done", "#34d399"},
    {"--running", "#38bdf8"},
    {"--escalated", "#fbbf24"},
    {"--halted", "#fb7185"},
    {"--failed", "#f43f5e"},
    {"--pending", "#64748b"},
    {"--blocked", "#475569"}
  ]

  @doc false
  def contract_colors, do: @contract_colors

  @retired_tokens ~w(--muted --accent-2 --link --link-hover)

  @radius_tokens ~w(--r-pip --r-chip --r-control --r-input --r-card --r-panel --r-dot)
  @type_tokens ~w(--fs-kpi --fs-subject --fs-title --fs-card-title --fs-section --fs-transcript --fs-body --fs-meta --fs-eyebrow)
  @spacing_tokens ~w(--sp-4 --sp-6 --sp-8 --sp-10 --sp-12 --sp-14 --sp-18 --sp-20 --sp-22)
  @font_family_tokens ~w(--font-sans --font-mono)
  @derived_tokens ~w(--scrim --shadow-drawer --shadow-toast --glow-accent --gradient-primary --selection --hatch-reserved)

  @allowed_root_names (@contract_colors |> Enum.map(&elem(&1, 0))) ++
                        @radius_tokens ++
                        @type_tokens ++
                        @spacing_tokens ++
                        @font_family_tokens ++
                        @derived_tokens

  @status_hexes Enum.filter(@contract_colors, fn {name, _} ->
                  name in ~w(--done --running --escalated --halted --failed --pending --blocked)
                end)

  @status_names ~w(done running escalated halted failed pending blocked)

  @spacing_grid [4, 6, 8, 10, 12, 14, 18, 20, 22]
  @layout_named_values ~w(236px 460px 280px)

  @approved_keyframes ~w(scPulse scBlink scSlide scFade)
  @animation_referents ~w(running active live drawer scrim toast)

  @approved_color_mix_pct [5, 10, 13, 25, 33, 40, 53]
  @approved_hex_alpha_suffixes ~w(0d 1a 22 40 55 66 88)

  @pictograph_allowlist MapSet.new([0x2713, 0x25CF, 0x2715])
  @pictograph_ranges [
    {0x1F300, 0x1FAFF},
    {0x2600, 0x27BF},
    {0x2B00, 0x2BFF},
    {0x25A0, 0x25FF},
    {0xFE0F, 0xFE0F}
  ]

  @named_color_re ~r/:\s*(white|black|red|green|blue|yellow|orange|purple|pink|gray|grey|cyan|magenta|lime|navy|teal|maroon|olive|silver|gold|indigo|violet|crimson|coral|salmon|khaki|plum|orchid|tan|beige|ivory)\s*[;,)]/i

  # ---- scan/1 (pure, G-1) ---------------------------------------------

  @doc "Pure. Every violation in the given sources, ordered by path then line."
  @spec scan(%{String.t() => String.t()}) :: [Violation.t()]
  def scan(sources) when is_map(sources) do
    css_source = Map.get(sources, @css_path)
    css_lines = css_source && String.split(css_source, "\n")
    root_span = css_lines && root_span(css_lines)

    css_violations = if css_source, do: scan_css(css_lines, root_span), else: []

    line_violations =
      sources
      |> Enum.reject(fn {path, _} -> path == @frozen_artifact_path end)
      |> Enum.flat_map(fn {path, source} ->
        span = if path == @css_path, do: root_span, else: nil
        scan_lines(path, source, span)
      end)

    frozen_violations =
      case Map.get(sources, @frozen_artifact_path) do
        nil -> []
        content -> scan_frozen(content)
      end

    (css_violations ++ line_violations ++ frozen_violations)
    |> Enum.sort_by(&{&1.path, &1.line})
  end

  @doc "Human-readable failure message: one line per violation, `path:line rule — excerpt`."
  @spec format([Violation.t()]) :: String.t()
  def format(violations) do
    violations
    |> Enum.map(fn v -> "#{v.path}:#{v.line} #{v.rule} — #{v.excerpt}" end)
    |> Enum.join("\n")
  end

  defp violation(rule, path, line, excerpt) do
    %Violation{rule: rule, path: path, line: max(line, 1), excerpt: String.slice(excerpt, 0, 160)}
  end

  # ---- frozen artifact --------------------------------------------------

  defp scan_frozen(content) do
    if content == @frozen_artifact_content do
      []
    else
      [
        violation(
          :frozen_artifact,
          @frozen_artifact_path,
          1,
          "content differs from the committed 011 contract"
        )
      ]
    end
  end

  # ---- brace-span helpers ------------------------------------------------

  defp count_char(str, char), do: str |> String.to_charlist() |> Enum.count(&(&1 == char))

  defp root_span(lines) do
    case Enum.find_index(lines, &String.starts_with?(&1, ":root {")) do
      nil -> nil
      start_idx -> {start_idx, close_index(lines, start_idx)}
    end
  end

  defp media_reduced_motion_span(lines) do
    case Enum.find_index(lines, &String.contains?(&1, "prefers-reduced-motion: reduce")) do
      nil -> nil
      start_idx -> {start_idx, close_index(lines, start_idx)}
    end
  end

  defp close_index(lines, start_idx) do
    {end_idx, _depth} =
      lines
      |> Enum.with_index()
      |> Enum.drop(start_idx)
      |> Enum.reduce_while({start_idx, 0}, fn {line, idx}, {_last, depth} ->
        depth = depth + count_char(line, ?{) - count_char(line, ?})
        if depth == 0, do: {:halt, {idx, depth}}, else: {:cont, {idx, depth}}
      end)

    end_idx
  end

  defp inside?(nil, _idx), do: false
  defp inside?({s, e}, idx), do: idx >= s and idx <= e

  # ---- CSS-only whole-file rules -----------------------------------------

  defp scan_css(lines, root_span) do
    token_violations(lines, root_span) ++
      motion_violations(lines) ++
      governing_source_violations(lines) ++
      centered_body_text_violations(lines, root_span)
  end

  @body_role_tokens ~w(--fs-body --fs-meta --fs-section --fs-transcript)

  # Needs block context (§VIII): only a violation when the SAME rule also
  # sets a body-copy-role font-size token, not any centered element (a small
  # numeric badge legitimately centers on `--fs-eyebrow`).
  defp centered_body_text_violations(lines, root_span) do
    lines
    |> top_level_blocks(root_span)
    |> Enum.filter(fn block ->
      body_text = Enum.join(block.body, "\n")

      Regex.match?(~r/text-align:\s*center/, body_text) and
        Enum.any?(@body_role_tokens, &String.contains?(body_text, "var(#{&1})"))
    end)
    |> Enum.map(fn block ->
      violation(:centered_body_text, @css_path, block.start_line, block.selector || "")
    end)
  end

  defp governing_source_violations(lines) do
    header = lines |> Enum.take(12) |> Enum.join("\n")

    cond do
      not String.contains?(header, "docs/design-constitution.md") ->
        [
          violation(
            :governing_source,
            @css_path,
            1,
            "header does not cite docs/design-constitution.md"
          )
        ]

      Regex.match?(~r/Governing contract:\s*specs\/011/, header) ->
        [violation(:governing_source, @css_path, 1, "header cites the 011 contract as governing")]

      true ->
        []
    end
  end

  defp token_violations(_lines, nil) do
    Enum.map(@contract_colors, fn {name, _} ->
      violation(:missing_token, @css_path, 1, "#{name} not declared (:root not found)")
    end)
  end

  defp token_violations(lines, root_span) do
    decls = root_declarations(lines, root_span)
    decl_map = Map.new(decls, fn {name, value, line} -> {name, {value, line}} end)

    missing =
      for {name, _expected} <- @contract_colors, not Map.has_key?(decl_map, name) do
        violation(:missing_token, @css_path, elem(root_span, 0) + 1, "#{name} not declared")
      end

    mismatched =
      for {name, expected} <- @contract_colors, {value, line} <- [Map.get(decl_map, name)] do
        cond do
          value == nil ->
            []

          String.downcase(value) != String.downcase(expected) ->
            [
              violation(
                :token_value_mismatch,
                @css_path,
                line,
                "#{name}: #{value} (expected #{expected})"
              )
            ]

          true ->
            []
        end
      end
      |> List.flatten()

    collisions = collision_violations(decls)
    retired = retired_declared_violations(decls, lines)
    undeclared = undeclared_token_violations(lines, decls, root_span)
    unexpected = unexpected_token_violations(decls)
    sub_floor = sub_floor_violations(decls)

    missing ++ mismatched ++ collisions ++ retired ++ undeclared ++ unexpected ++ sub_floor
  end

  defp collision_violations(decls) do
    contract_names = MapSet.new(@contract_colors, &elem(&1, 0))

    decls
    |> Enum.filter(fn {name, _value, _line} -> MapSet.member?(contract_names, name) end)
    |> Enum.group_by(fn {_name, value, _line} -> String.downcase(value) end)
    |> Enum.flat_map(fn {_value, group} ->
      if length(group) > 1 do
        Enum.map(group, fn {name, value, line} ->
          violation(
            :token_value_mismatch,
            @css_path,
            line,
            "#{name}: #{value} collides with another §II token"
          )
        end)
      else
        []
      end
    end)
  end

  defp retired_declared_violations(decls, lines) do
    declared =
      for {name, _value, line} <- decls, name in @retired_tokens do
        violation(:retired_token, @css_path, line, "#{name} declared in :root")
      end

    referenced =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, idx} ->
        for name <- @retired_tokens, String.contains?(line, "var(#{name})") do
          violation(:retired_token, @css_path, idx + 1, "var(#{name}) referenced")
        end
      end)

    declared ++ referenced
  end

  defp undeclared_token_violations(lines, decls, root_span) do
    # `--sc` (and any other locally-scoped custom property, e.g. inside
    # `[data-status="x"] { --sc: var(--done); }`) is declared outside
    # `:root` by design (status-transport.md §3) — declared anywhere in the
    # file counts, not just inside `:root`.
    file_declared =
      ~r/^\s*(--[a-zA-Z0-9-]+)\s*:/m
      |> Regex.scan(Enum.join(lines, "\n"))
      |> Enum.map(fn [_, name] -> name end)

    declared =
      MapSet.new(decls, fn {name, _v, _l} -> name end) |> MapSet.union(MapSet.new(file_declared))

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      if inside?(root_span, idx) do
        []
      else
        ~r/var\((--[a-zA-Z0-9-]+)/
        |> Regex.scan(line)
        |> Enum.flat_map(fn [_, name] ->
          if MapSet.member?(declared, name) do
            []
          else
            [
              violation(
                :undeclared_token,
                @css_path,
                idx + 1,
                "var(#{name}) — not declared in :root"
              )
            ]
          end
        end)
      end
    end)
  end

  defp unexpected_token_violations(decls) do
    allowed = MapSet.new(@allowed_root_names)

    for {name, value, line} <- decls, not MapSet.member?(allowed, name) do
      [
        violation(
          :unexpected_token,
          @css_path,
          line,
          "#{name} declared outside the token families"
        )
      ] ++
        if Regex.match?(~r/^#[0-9a-fA-F]{3,8}/, String.trim(value)) do
          [
            violation(
              :second_accent_hue,
              @css_path,
              line,
              "#{name}: #{value} — off-contract color"
            )
          ]
        else
          []
        end
    end
    |> List.flatten()
  end

  defp sub_floor_violations(decls) do
    for {name, value, line} <- decls, String.starts_with?(name, "--fs-") do
      case Regex.run(~r/^(\d+(?:\.\d+)?)px/, String.trim(value)) do
        [_, n] ->
          if to_float(n) < 10.0 do
            [
              violation(
                :sub_floor_type,
                @css_path,
                line,
                "#{name}: #{value} below the 10px floor"
              )
            ]
          else
            []
          end

        nil ->
          []
      end
    end
    |> List.flatten()
  end

  defp to_float(n) do
    if String.contains?(n, "."),
      do: String.to_float(n),
      else: n |> String.to_integer() |> :erlang.float()
  end

  defp root_declarations(lines, {start_idx, end_idx}) do
    span_lines = Enum.slice(lines, start_idx..end_idx)
    text = Enum.join(span_lines, "\n")

    ~r/(--[a-zA-Z0-9-]+)\s*:\s*([^;]*);/
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{_ds, _dl}, {ns, nl}, {vs, vl}] ->
      name = binary_part(text, ns, nl)
      value = text |> binary_part(vs, vl) |> String.trim()
      line_no = start_idx + newline_count(text, ns) + 1
      {name, value, line_no}
    end)
  end

  defp newline_count(text, upto_byte) do
    text
    |> binary_part(0, upto_byte)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
  end

  # ---- motion (CSS-only) --------------------------------------------------

  defp motion_violations(lines) do
    text = Enum.join(lines, "\n")

    keyframe_names =
      ~r/@keyframes\s+([A-Za-z0-9_]+)\s*\{/
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [_, {ns, nl}] ->
        name = binary_part(text, ns, nl)
        line = newline_count(text, ns) + 1
        {name, line}
      end)

    unknown_kf =
      for {name, line} <- keyframe_names, name not in @approved_keyframes do
        violation(:unknown_keyframe, @css_path, line, "@keyframes #{name}")
      end

    declared_names = Enum.map(keyframe_names, &elem(&1, 0))

    missing_kf =
      if Enum.count(@approved_keyframes, &(&1 in declared_names)) < 4 do
        missing = @approved_keyframes -- declared_names
        [violation(:missing_keyframe, @css_path, 1, "missing: #{Enum.join(missing, ", ")}")]
      else
        []
      end

    media_span = media_reduced_motion_span(lines)
    outer_blocks = top_level_blocks(lines, media_span)

    reduced_selectors =
      case media_span do
        nil ->
          MapSet.new()

        {s, e} ->
          lines
          |> Enum.slice((s + 1)..(e - 1))
          |> top_level_blocks(nil)
          |> Enum.flat_map(fn block -> split_selectors(block.selector) end)
          |> MapSet.new()
      end

    animated_blocks =
      Enum.filter(outer_blocks, fn block ->
        Enum.any?(block.body, &Regex.match?(~r/animation:\s*[a-zA-Z]/, &1))
      end)

    {referent_v, undefined_v, unstoppable_v} =
      Enum.reduce(animated_blocks, {[], [], []}, fn block, {ref_acc, undef_acc, stop_acc} ->
        anim_line = Enum.find(block.body, &Regex.match?(~r/animation:\s*[a-zA-Z]/, &1))
        [_, kf_name] = Regex.run(~r/animation:\s*([a-zA-Z][\w]*)/, anim_line)
        selectors = split_selectors(block.selector)

        ref_violations =
          for sel <- selectors,
              not Enum.any?(@animation_referents, &String.contains?(sel, &1)) do
            violation(:animation_without_referent, @css_path, block.start_line, sel)
          end

        undef_violations =
          if kf_name in declared_names do
            []
          else
            [
              violation(
                :undefined_animation,
                @css_path,
                block.start_line,
                "animation: #{kf_name}"
              )
            ]
          end

        stop_violations =
          for sel <- selectors, not MapSet.member?(reduced_selectors, sel) do
            violation(:unstoppable_keyframe, @css_path, block.start_line, sel)
          end

        {ref_acc ++ ref_violations, undef_acc ++ undef_violations, stop_acc ++ stop_violations}
      end)

    unknown_kf ++ missing_kf ++ referent_v ++ undefined_v ++ unstoppable_v
  end

  defp split_selectors(nil), do: []

  defp split_selectors(selector) do
    selector
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Single-pass, non-nesting block parser tuned to this stylesheet's
  # formatting (one rule per selector/body span; `@media`/`@keyframes`
  # bodies are skipped over, either via `exclude_span` or because their
  # own nested braces are treated as harmless opaque body text — this
  # parser is never used to look inside them).
  defp top_level_blocks(lines, exclude_span) do
    {acc, _, _, _, _, _, _} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], [], nil, nil, false, [], false}, fn {line, idx},
                                                              {acc, sel_buf, cur_sel, start_line,
                                                               in_block, body, in_comment} ->
        trimmed = String.trim(line)
        excluded? = exclude_span != nil and inside?(exclude_span, idx)

        cond do
          excluded? ->
            {acc, sel_buf, cur_sel, start_line, in_block, body, in_comment}

          in_comment ->
            {acc, sel_buf, cur_sel, start_line, in_block, body, not String.contains?(line, "*/")}

          in_block and String.contains?(line, "}") ->
            block = %{
              selector: cur_sel,
              body: Enum.reverse(body),
              start_line: start_line,
              end_line: idx + 1
            }

            {[block | acc], [], nil, nil, false, [], false}

          in_block ->
            {acc, sel_buf, cur_sel, start_line, in_block, [line | body], false}

          String.contains?(trimmed, "/*") and not String.contains?(trimmed, "*/") ->
            {acc, sel_buf, cur_sel, start_line, in_block, body, true}

          String.starts_with?(trimmed, "/*") ->
            {acc, sel_buf, cur_sel, start_line, in_block, body, false}

          String.contains?(line, "{") ->
            pre = line |> String.split("{") |> List.first()
            full_sel = (sel_buf ++ [pre]) |> Enum.join(" ") |> String.trim()
            {acc, [], full_sel, idx + 1, true, [], false}

          trimmed == "" or String.starts_with?(trimmed, "@") ->
            {acc, [], nil, nil, false, [], false}

          true ->
            {acc, sel_buf ++ [trimmed], nil, nil, false, [], false}
        end
      end)

    Enum.reverse(acc)
  end

  # ---- per-line rules (all surfaces) --------------------------------------

  defp scan_lines(path, source, span) do
    lines = String.split(source, "\n")
    css? = path == @css_path
    elixir_web? = not css? and path != "priv/static/assets/app.js"

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      inside_root? = css? and inside?(span, idx)
      line_no = idx + 1

      []
      |> add(color_literal(path, line, line_no, css?, inside_root?))
      |> add(duplicate_status(path, line, line_no, css?, inside_root?))
      |> add(illegal_alpha(path, line, line_no))
      |> add(inline_style_color(path, line, line_no))
      |> add(pictograph(path, line, line_no))
      |> add(pure_black_white(path, line, line_no, css?, inside_root?))
      |> add(background_gradient(path, line, line_no, css?, inside_root?))
      |> add(offscale_radius(path, line, line_no, css?, inside_root?))
      |> add(offscale_font_size(path, line, line_no, css?, inside_root?))
      |> add(offgrid_spacing(path, line, line_no, css?, inside_root?))
      |> add(shadow_on_resting(path, line, line_no, css?))
      |> add(unknown_status_selector(path, line, line_no, css?))
      |> add(status_color_in_elixir(path, line, line_no, elixir_web?))
    end)
  end

  defp add(acc, nil), do: acc
  defp add(acc, list) when is_list(list), do: acc ++ list
  defp add(acc, %Violation{} = v), do: acc ++ [v]

  @hex_re ~r/#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b/
  @color_fn_re ~r/\b(?:rgba?|hsla?)\(/

  defp color_literal(path, line, line_no, css?, inside_root?) do
    cond do
      css? and inside_root? ->
        nil

      String.starts_with?(String.trim(line), "/*") ->
        nil

      Regex.match?(@hex_re, line) or Regex.match?(@color_fn_re, line) or
          Regex.match?(@named_color_re, line) ->
        violation(:color_literal, path, line_no, String.trim(line))

      true ->
        nil
    end
  end

  defp duplicate_status(path, line, line_no, css?, inside_root?) do
    if css? and inside_root? do
      nil
    else
      Enum.find_value(@status_hexes, fn {_name, hex} ->
        re = Regex.compile!(Regex.escape(hex) <> "([0-9a-fA-F]{2})?\\b", "i")

        if Regex.match?(re, line) do
          violation(:duplicate_status_value, path, line_no, String.trim(line))
        end
      end)
    end
  end

  defp illegal_alpha(path, line, line_no) do
    color_mix_violations =
      ~r/color-mix\(in srgb,.*?(\d+)%/
      |> Regex.scan(line)
      |> Enum.flat_map(fn [_, pct] ->
        if String.to_integer(pct) in @approved_color_mix_pct do
          []
        else
          [violation(:illegal_alpha_suffix, path, line_no, String.trim(line))]
        end
      end)

    hex_alpha_violations =
      ~r/#[0-9a-fA-F]{6}([0-9a-fA-F]{2})\b/
      |> Regex.scan(line)
      |> Enum.flat_map(fn [_, suffix] ->
        if String.downcase(suffix) in @approved_hex_alpha_suffixes do
          []
        else
          [violation(:illegal_alpha_suffix, path, line_no, String.trim(line))]
        end
      end)

    case color_mix_violations ++ hex_alpha_violations do
      [] -> nil
      list -> list
    end
  end

  # Exactly two loci are allowlisted (design-guard.md §3.4): `cost_gauge/1`'s
  # two fill-width styles. Anything else carrying `style=` fires.
  @allowed_inline_style_re ~r/style=\{"width:\s*#\{@(?:fill|committed_fill)\}%;"\}/

  defp inline_style_color(path, line, line_no) do
    case Regex.scan(~r/style=\{"[^"]*"\}/, line) do
      [] ->
        nil

      matches ->
        if Enum.all?(matches, fn [m] -> Regex.match?(@allowed_inline_style_re, m) end) do
          nil
        else
          violation(:inline_style_color, path, line_no, String.trim(line))
        end
    end
  end

  defp decode_entities(line) do
    line
    |> then(
      &Regex.replace(~r/&#x([0-9a-fA-F]+);/, &1, fn _, hex ->
        <<String.to_integer(hex, 16)::utf8>>
      end)
    )
    |> then(&Regex.replace(~r/&#(\d+);/, &1, fn _, dec -> <<String.to_integer(dec)::utf8>> end))
  end

  defp pictograph(path, line, line_no) do
    decoded = decode_entities(line)

    offending =
      decoded
      |> String.to_charlist()
      |> Enum.find(fn cp ->
        not MapSet.member?(@pictograph_allowlist, cp) and
          Enum.any?(@pictograph_ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)
      end)

    if offending do
      violation(:pictograph, path, line_no, String.trim(decoded))
    end
  end

  @shadow_tokens ~w(--shadow-drawer --shadow-toast --glow-accent)

  defp pure_black_white(path, line, line_no, css?, inside_root?) do
    if css? and inside_root? do
      nil
    else
      if Regex.match?(~r/#(?:000000|000|ffffff|fff)\b/i, line) or
           Regex.match?(~r/:\s*(?:white|black)\s*[;,)]/i, line) or
           Regex.match?(
             ~r/rgb\(\s*0\s*,\s*0\s*,\s*0\s*\)|rgb\(\s*255\s*,\s*255\s*,\s*255\s*\)/i,
             line
           ) do
        violation(:pure_black_white, path, line_no, String.trim(line))
      end
    end
  end

  defp background_gradient(path, line, line_no, css?, inside_root?) do
    if String.contains?(line, "gradient(") and not (css? and inside_root?) do
      violation(:background_gradient, path, line_no, String.trim(line))
    end
  end

  defp offscale_radius(path, line, line_no, css?, inside_root?) do
    if css? and inside_root? do
      nil
    else
      case Regex.run(~r/^\s*border-radius\s*:\s*([^;]+);/, line) do
        [_, value] ->
          if Regex.match?(~r/^var\(--r-[\w-]+\)$/, String.trim(value)) do
            nil
          else
            violation(:offscale_radius, path, line_no, String.trim(line))
          end

        nil ->
          nil
      end
    end
  end

  defp offscale_font_size(path, line, line_no, css?, inside_root?) do
    if css? and inside_root? do
      nil
    else
      case Regex.run(~r/^\s*font-size\s*:\s*([^;]+);/, line) do
        [_, value] ->
          if Regex.match?(~r/^var\(--fs-[\w-]+\)$/, String.trim(value)) do
            nil
          else
            violation(:offscale_font_size, path, line_no, String.trim(line))
          end

        nil ->
          nil
      end
    end
  end

  defp offgrid_spacing(path, line, line_no, css?, inside_root?) do
    if css? and inside_root? do
      nil
    else
      case Regex.run(
             ~r/^\s*(padding|margin|gap|top|right|bottom|left)(-\w+)?\s*:\s*([^;]+);\s*$/,
             line
           ) do
        [_, _prop, _side, value] ->
          bad? =
            ~r/(-?\d+(?:\.\d+)?)px/
            |> Regex.scan(value)
            |> Enum.any?(fn [full, n] ->
              f = String.to_float(n <> if(String.contains?(n, "."), do: "", else: ".0"))
              mag = abs(trunc(f))

              not (mag == 0 or mag in @spacing_grid or full in @layout_named_values or
                     String.trim(value) in @layout_named_values)
            end)

          if bad?, do: violation(:offgrid_spacing, path, line_no, String.trim(line))

        nil ->
          nil
      end
    end
  end

  defp shadow_on_resting(_path, _line, _line_no, false), do: nil

  defp shadow_on_resting(path, line, line_no, true) do
    case Regex.run(~r/box-shadow:\s*([^;]+);/, line) do
      [_, value] ->
        trimmed = String.trim(value)

        allowed? =
          Enum.any?(@shadow_tokens, fn tok ->
            trimmed == "var(#{tok})" or String.contains?(trimmed, tok)
          end)

        if allowed?,
          do: nil,
          else: violation(:shadow_on_resting, path, line_no, String.trim(line))

      nil ->
        nil
    end
  end

  defp unknown_status_selector(_path, _line, _line_no, false), do: nil

  # `.status-x` class selectors are the contract's documented alternative to
  # `[data-status="x"]` (status-transport.md §2), but this codebase uses the
  # attribute form exclusively — component names like `.status-chip` /
  # `.status-dot` merely share the "status-" prefix and are not per-status
  # variants, so only the attribute form is checked here.
  defp unknown_status_selector(path, line, line_no, true) do
    ~r/\[data-status="([a-zA-Z0-9_-]+)"\]/
    |> Regex.scan(line)
    |> Enum.find_value(fn [_, name] ->
      if name not in @status_names, do: violation(:unknown_status_selector, path, line_no, name)
    end)
  end

  defp status_color_in_elixir(_path, _line, _line_no, false), do: nil

  defp status_color_in_elixir(path, line, line_no, true) do
    has_status_name? = Enum.any?(@status_names, &String.contains?(line, &1))

    has_color_prop? =
      Regex.match?(~r/\b(color|background|background-color|border-color)\s*[:,]/, line)

    hex_or_status = Regex.match?(@hex_re, line)

    if (has_status_name? and has_color_prop?) or (has_status_name? and hex_or_status) do
      violation(:status_color_in_elixir, path, line_no, String.trim(line))
    end
  end
end
