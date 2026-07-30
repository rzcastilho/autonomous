defmodule SpeckitOrchestrator.Web.DesignContractTest do
  @moduledoc """
  Driver for `SpeckitOrchestrator.Web.DesignContract`
  (contracts/design-guard.md §4). Hermetic (FR-024): no `@tag :integration`,
  no Coordinator, no socket — every case is either the real tree read once
  via `load/1` or a crafted `%{path => source}` map handed straight to the
  pure `scan/1`.
  """

  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Web.DesignContract

  @root File.cwd!()

  # ---- 1. clean tree (FR-023, SC-007) -------------------------------------

  describe "the reconciled tree" do
    test "scans clean" do
      violations = @root |> DesignContract.load() |> DesignContract.scan()

      assert violations == [],
             "design contract violations found:\n" <> DesignContract.format(violations)
    end
  end

  # ---- 2. coverage (G-6) ---------------------------------------------------

  describe "surfaces/0" do
    test "matches the on-disk console surface set" do
      on_disk =
        MapSet.new(
          [
            "priv/static/assets/console.css",
            "priv/static/assets/app.js",
            "lib/speckit_orchestrator/web/components/core_components.ex",
            "lib/speckit_orchestrator/web/components/feature_drawer.ex",
            "lib/speckit_orchestrator/web/components/layouts.ex",
            "lib/speckit_orchestrator/web/components/layouts/app.html.heex",
            "lib/speckit_orchestrator/web/components/layouts/root.html.heex"
          ] ++
            ("lib/speckit_orchestrator/web/live/*.ex"
             |> then(&Path.wildcard(Path.join(@root, &1)))
             |> Enum.map(&Path.relative_to(&1, @root)))
        )

      assert MapSet.new(DesignContract.surfaces()) == on_disk
    end

    test "every declared surface exists on disk" do
      for path <- DesignContract.surfaces() do
        assert File.regular?(Path.join(@root, path)), "#{path} does not exist"
      end
    end
  end

  # ---- 3. doc transcription (G-7) ------------------------------------------

  describe "the embedded §II token table" do
    test "matches the fenced CSS block in docs/design-constitution.md" do
      doc = File.read!(Path.join(@root, "docs/design-constitution.md"))
      [_, fenced] = Regex.run(~r/```css\n(.*?)```/s, doc)

      doc_pairs =
        ~r/(--[a-zA-Z-]+)\s*:\s*(#[0-9a-fA-F]{6})/
        |> Regex.scan(fenced)
        |> Enum.map(fn [_, name, value] -> {name, value} end)
        |> MapSet.new()

      assert MapSet.new(DesignContract.contract_colors()) == doc_pairs
    end
  end

  # ---- 4. the four required injections (SC-007) ----------------------------

  describe "required injections" do
    test "a color literal appended to a CSS surface fires :duplicate_status_value and :color_literal" do
      violations =
        DesignContract.scan(%{"priv/static/assets/console.css" => ".foo { color: #34d399; }"})

      assert_fires(violations, :color_literal, 1)
      assert_fires(violations, :duplicate_status_value, 1)
    end

    test "a color literal in a view source fires :color_literal" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/live/config_live.ex" => "defp c, do: \"#7c5cff\"\n"
        })

      assert_fires(violations, :color_literal, 1)
    end

    test "a fifth keyframe fires :unknown_keyframe" do
      violations =
        DesignContract.scan(%{
          "priv/static/assets/console.css" => "@keyframes scWobble { 0% { opacity: 1; } }"
        })

      assert_fires(violations, :unknown_keyframe, 1)
    end

    test "a prohibited inline style in a view source fires :inline_style_color" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/live/config_live.ex" =>
            ~S(  style={"background: #{@c};"}) <> "\n"
        })

      assert_fires(violations, :inline_style_color, 1)
    end
  end

  defp assert_fires(violations, rule, line) do
    assert Enum.any?(violations, &(&1.rule == rule and &1.line == line)),
           "expected #{rule} at line #{line}, got:\n#{DesignContract.format(violations)}"
  end

  defp refute_fires(violations, rule) do
    refute Enum.any?(violations, &(&1.rule == rule)),
           "did not expect #{rule}, got:\n#{DesignContract.format(violations)}"
  end

  # ---- 5. every other rule: one positive + one negative case (G-4, >90%) ---

  setup_all do
    base = DesignContract.load(@root)
    {:ok, base: base, css: Map.fetch!(base, "priv/static/assets/console.css")}
  end

  describe "token integrity" do
    test "missing_token fires when a §II token is absent from :root", %{css: css} do
      mutated = String.replace(css, "--bg: #0b0d12; ", "", global: false)
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :missing_token)
    end

    test "missing_token does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :missing_token)
    end

    test "token_value_mismatch fires when a §II token's value differs from the contract", %{
      css: css
    } do
      mutated = String.replace(css, "--bg: #0b0d12;", "--bg: #0b0d13;", global: false)
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :token_value_mismatch)
    end

    test "token_value_mismatch fires when two §II tokens share a value", %{css: css} do
      mutated = String.replace(css, "--bg: #0b0d12;", "--bg: #0e1016;", global: false)
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :token_value_mismatch)
    end

    test "token_value_mismatch does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :token_value_mismatch)
    end

    test "retired_token fires when --muted is declared in :root", %{css: css} do
      mutated = String.replace(css, ":root {", ":root {\n  --muted: #5a6274;", global: false)
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :retired_token)
    end

    test "retired_token fires when --link is referenced outside :root", %{css: css} do
      mutated = css <> "\n.foo { color: var(--link); }\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :retired_token)
    end

    test "retired_token does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :retired_token)
    end

    test "undeclared_token fires when var() names an undeclared custom property", %{css: css} do
      mutated = css <> "\n.foo { color: var(--totally-fake); }\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :undeclared_token)
    end

    test "undeclared_token does not fire on --sc (locally scoped, not root-declared)", %{
      base: base
    } do
      refute_fires(DesignContract.scan(base), :undeclared_token)
    end

    test "unexpected_token fires when :root declares a name outside the token families", %{
      css: css
    } do
      mutated =
        String.replace(css, ":root {", ":root {\n  --my-invented-token: 5px;", global: false)

      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :unexpected_token)
    end

    test "unexpected_token does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :unexpected_token)
    end
  end

  describe "literals" do
    test "color_literal does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :color_literal)
    end

    test "offscale_radius fires on a raw border-radius literal", %{css: css} do
      mutated = css <> "\n.foo {\n  border-radius: 3px;\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :offscale_radius)
    end

    test "offscale_radius does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :offscale_radius)
    end

    test "offscale_font_size fires on a raw font-size literal", %{css: css} do
      mutated = css <> "\n.foo {\n  font-size: 15px;\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :offscale_font_size)
    end

    test "offscale_font_size does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :offscale_font_size)
    end

    test "offgrid_spacing fires on a padding value off the 2px rhythm", %{css: css} do
      mutated = css <> "\n.foo {\n  padding: 7px;\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :offgrid_spacing)
    end

    test "offgrid_spacing does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :offgrid_spacing)
    end

    test "illegal_alpha_suffix fires on an unapproved color-mix percentage", %{css: css} do
      mutated =
        css <> "\n.foo { background: color-mix(in srgb, var(--sc) 45%, transparent); }\n"

      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :illegal_alpha_suffix)
    end

    test "illegal_alpha_suffix fires on an unapproved hex alpha suffix", %{css: css} do
      mutated =
        String.replace(css, "--selection: #7c5cff55;", "--selection: #7c5cff99;", global: false)

      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :illegal_alpha_suffix)
    end

    test "illegal_alpha_suffix does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :illegal_alpha_suffix)
    end
  end

  describe "status duplication" do
    test "duplicate_status_value does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :duplicate_status_value)
    end

    test "unknown_status_selector fires on a [data-status] value outside the seven", %{css: css} do
      mutated = css <> "\n[data-status=\"funky\"] { --sc: var(--done); }\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :unknown_status_selector)
    end

    test "unknown_status_selector does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :unknown_status_selector)
    end

    test "status_color_in_elixir fires on a status name adjacent to a color literal" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/live/config_live.ex" =>
            "defp escalated_color, do: \"#fbbf24\"\n"
        })

      assert_fires_rule(violations, :status_color_in_elixir)
    end

    test "status_color_in_elixir does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :status_color_in_elixir)
    end
  end

  describe "inline styles" do
    test "inline_style_color does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :inline_style_color)
    end

    test "the two allowlisted cost-gauge fill styles alone do not fire" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/components/core_components.ex" =>
            ~S(<div style={"width: #{@fill}%;"}></div>) <> "\n"
        })

      refute_fires(violations, :inline_style_color)
    end
  end

  describe "motion" do
    test "missing_keyframe fires when fewer than four are declared" do
      css = "@keyframes scPulse { 0% { opacity: 1; } } @keyframes scBlink { 0% { opacity: 1; } }"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => css})
      assert_fires_rule(violations, :missing_keyframe)
    end

    test "missing_keyframe does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :missing_keyframe)
    end

    test "undefined_animation fires when animation: names an undeclared keyframe", %{css: css} do
      mutated = css <> "\n.foo-running {\n  animation: scGhost 1s;\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :undefined_animation)
    end

    test "undefined_animation does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :undefined_animation)
    end

    test "animation_without_referent fires on a selector naming no live referent", %{css: css} do
      mutated = css <> "\n.quux {\n  animation: scPulse 1s;\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :animation_without_referent)
    end

    test "animation_without_referent does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :animation_without_referent)
    end

    test "unstoppable_keyframe fires on a live selector absent from the reduced-motion block", %{
      css: css
    } do
      mutated = css <> "\n.something-running {\n  animation: scPulse 1s;\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :unstoppable_keyframe)
    end

    test "unstoppable_keyframe does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :unstoppable_keyframe)
    end
  end

  describe "§VIII prohibitions" do
    test "pure_black_white fires on a raw white/black value", %{css: css} do
      mutated = css <> "\n.foo { color: white; }\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :pure_black_white)
    end

    test "pure_black_white does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :pure_black_white)
    end

    test "background_gradient fires outside the two permitted tokens", %{css: css} do
      mutated = css <> "\n.foo { background: linear-gradient(90deg, red, blue); }\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :background_gradient)
    end

    test "background_gradient does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :background_gradient)
    end

    test "second_accent_hue fires on an off-contract hex declared in :root", %{css: css} do
      mutated = String.replace(css, ":root {", ":root {\n  --off-hue: #123456;", global: false)
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :second_accent_hue)
    end

    test "second_accent_hue does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :second_accent_hue)
    end

    test "centered_body_text fires only when the same rule sets a body-role font-size", %{
      css: css
    } do
      mutated = css <> "\n.prose {\n  text-align: center;\n  font-size: var(--fs-body);\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :centered_body_text)
    end

    test "centered_body_text does not fire when centered text uses a non-body-role token", %{
      css: css
    } do
      mutated = css <> "\n.badge {\n  text-align: center;\n  font-size: var(--fs-eyebrow);\n}\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      refute_fires(violations, :centered_body_text)
    end

    test "centered_body_text does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :centered_body_text)
    end

    test "sub_floor_type fires on a --fs- token declared below 10px", %{css: css} do
      mutated = String.replace(css, ":root {", ":root {\n  --fs-tiny: 8px;", global: false)
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :sub_floor_type)
    end

    test "sub_floor_type does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :sub_floor_type)
    end

    test "pictograph fires on an emoji in a view source" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/live/config_live.ex" => "  \"\u{1F680} launch\"\n"
        })

      assert_fires_rule(violations, :pictograph)
    end

    test "pictograph fires on an HTML numeric entity" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/live/config_live.ex" => "&#9654; Go\n"
        })

      assert_fires_rule(violations, :pictograph)
    end

    test "pictograph allows the timeline mark codepoints" do
      violations =
        DesignContract.scan(%{
          "lib/speckit_orchestrator/web/components/feature_drawer.ex" => "\"✓\"\n"
        })

      refute_fires(violations, :pictograph)
    end

    test "pictograph does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :pictograph)
    end

    test "shadow_on_resting fires on a box-shadow outside the three shadow tokens", %{css: css} do
      mutated = css <> "\n.static-card { box-shadow: 0 2px 4px var(--border); }\n"
      violations = DesignContract.scan(%{"priv/static/assets/console.css" => mutated})
      assert_fires_rule(violations, :shadow_on_resting)
    end

    test "shadow_on_resting does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :shadow_on_resting)
    end

    test "governing_source fires when the header omits docs/design-constitution.md" do
      violations =
        DesignContract.scan(%{"priv/static/assets/console.css" => ".foo { color: var(--bg); }"})

      assert_fires_rule(violations, :governing_source)
    end

    test "governing_source fires when the header cites the 011 contract as governing" do
      header =
        "/* Governing contract: specs/011-control-plane-ui-redesign/contracts/design-system.md */\n"

      violations = DesignContract.scan(%{"priv/static/assets/console.css" => header})
      assert_fires_rule(violations, :governing_source)
    end

    test "governing_source does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :governing_source)
    end

    test "frozen_artifact fires when the 011 contract's content differs" do
      violations =
        DesignContract.scan(%{
          "specs/011-control-plane-ui-redesign/contracts/design-system.md" => "mutated"
        })

      assert_fires_rule(violations, :frozen_artifact)
    end

    test "frozen_artifact does not fire on the real tree", %{base: base} do
      refute_fires(DesignContract.scan(base), :frozen_artifact)
    end
  end

  defp assert_fires_rule(violations, rule) do
    assert Enum.any?(violations, &(&1.rule == rule)),
           "expected #{rule}, got:\n#{DesignContract.format(violations)}"
  end
end
