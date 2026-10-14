defmodule Autonomous.VolumesPyTest do
  @moduledoc "Foundational tests for `scripts/volumes.py` parsing (feature 041, T007)."
  use Autonomous.VolumesCase, async: true

  describe "parse/1" do
    test "empty text, comments only and `volume = []` declare zero entries" do
      assert {:ok, []} = parse_text("")
      assert {:ok, []} = parse_text("# nothing here\n\n# still nothing\n")
      assert {:ok, []} = parse_text("volume = []\n")
    end

    test "entries keep declaration order and every field" do
      text = """
      [[volume]]
      name = "b"
      path = "/var/lib/autonomous/volumes/b"
      path_dirs = ["/var/lib/autonomous/volumes/b/bin"]
      [volume.env]
      CARGO_HOME = "/var/lib/autonomous/volumes/b"

      [[volume]]
      name = "a"
      path = "/var/lib/autonomous/volumes/a"
      env = { X = "1" }
      """

      assert {:ok, [first, second]} = parse_text(text)
      assert first["name"] == "b"
      assert first["path_dirs"] == ["/var/lib/autonomous/volumes/b/bin"]
      assert first["env"] == %{"CARGO_HOME" => "/var/lib/autonomous/volumes/b"}
      assert second["name"] == "a"
      assert second["env"] == %{"X" => "1"}
    end

    test "invalid TOML is malformed and names the file" do
      assert {:malformed, msg} = parse_text("[[volume]\nname = ")
      assert msg =~ "volumes.toml: not valid TOML:"
    end

    test "an unknown top-level key is malformed" do
      assert {:malformed, msg} = parse_text("[[volumes]]\nname = \"x\"\n")
      assert msg =~ "volumes.toml: not valid TOML:"
      assert msg =~ "volumes"
    end

    test "`volume` of the wrong shape is malformed" do
      assert {:malformed, _} = parse_text("volume = \"x\"\n")
      assert {:malformed, _} = parse_text("volume = [1, 2]\n")
    end

    test "unknown entry keys survive parsing (validate reports them)" do
      assert {:ok, [entry]} = parse_text("[[volume]]\nname = \"x\"\nsize = 5\n")
      assert entry["size"] == 5
    end
  end

  describe "command line" do
    test "an unknown subcommand is a usage error", ctx do
      assert {_, 2} = run_volumes(["bogus"], ctx)
    end
  end

  @parent "/var/lib/autonomous/volumes"

  defp ctx_json(ctx, extra \\ %{}) do
    ctx
    |> Map.take([:repo, :worktree_root, :state_root, :segment, :uid, :gid, :image_env])
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp plan!(ctx, text, extra \\ %{}) do
    path = write_declaration(ctx, text)

    {out, status} =
      run_volumes(["plan", "--declaration", path, "--context", ctx_json(ctx, extra)], ctx)

    {path, status, out}
  end

  defp decode_plan(out) do
    out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
  end

  describe "plan" do
    test "shapes volumes, docker names, env pairs and path dirs", ctx do
      {path, 0, out} =
        plan!(ctx, """
        [[volume]]
        name = "rust-toolchains"
        path = "#{@parent}/rust-toolchains"
        path_dirs = ["#{@parent}/rust-toolchains/cargo/bin"]
        [volume.env]
        RUSTUP_HOME = "#{@parent}/rust-toolchains/rustup"
        CARGO_HOME = "#{@parent}/rust-toolchains/cargo"

        [[volume]]
        name = "cargo-target"
        path = "#{@parent}/cargo-target"
        env = { CARGO_TARGET_DIR = "#{@parent}/cargo-target" }
        """)

      plan = decode_plan(out)
      assert [first, second] = plan["volumes"]
      assert first["name"] == "rust-toolchains"
      assert first["docker_name"] == "autonomous-t-1a2b_vol-rust-toolchains"

      assert first["env"] == [
               ["RUSTUP_HOME", "#{@parent}/rust-toolchains/rustup"],
               ["CARGO_HOME", "#{@parent}/rust-toolchains/cargo"]
             ]

      assert first["path_dirs"] == ["#{@parent}/rust-toolchains/cargo/bin"]
      assert second["env"] == [["CARGO_TARGET_DIR", "#{@parent}/cargo-target"]]
      assert second["path_dirs"] == []
      assert plan["notices"] == []
      assert path =~ "volumes.toml"
    end

    test "overlay mounts every shape with external named volumes", ctx do
      {_, 0, out} =
        plan!(ctx, """
        [[volume]]
        name = "cargo-target"
        path = "#{@parent}/cargo-target"
        env = { CARGO_TARGET_DIR = "#{@parent}/cargo-target" }
        """)

      overlay = decode_plan(out)["overlay"]
      assert Map.keys(overlay["services"]) |> Enum.sort() == ["console", "dev", "release"]

      for {_svc, spec} <- overlay["services"] do
        assert spec["volumes"] == [
                 %{
                   "type" => "volume",
                   "source" => "vol-cargo-target",
                   "target" => "#{@parent}/cargo-target"
                 }
               ]

        assert spec["environment"]["CARGO_TARGET_DIR"] == "#{@parent}/cargo-target"
      end

      assert overlay["volumes"] == %{
               "vol-cargo-target" => %{
                 "external" => true,
                 "name" => "autonomous-t-1a2b_vol-cargo-target"
               }
             }
    end

    test "PATH is set only with path dirs and is prefixed to the image PATH", ctx do
      toml = fn dirs ->
        """
        [[volume]]
        name = "a"
        path = "#{@parent}/a"
        path_dirs = #{Jason.encode!(dirs)}
        """
      end

      extra = %{image_env: ["PATH=/usr/bin:/bin", "LANG=C.UTF-8"]}

      {_, 0, out} = plan!(ctx, toml.([]), extra)
      env = decode_plan(out)["overlay"]["services"]["dev"]["environment"]
      refute Map.has_key?(env, "PATH")
      refute Map.has_key?(env, "AUTONOMOUS_VOLUME_PATH")

      {_, 0, out} = plan!(ctx, toml.(["#{@parent}/a/bin", "#{@parent}/a/sbin"]), extra)
      env = decode_plan(out)["overlay"]["services"]["dev"]["environment"]
      assert env["PATH"] == "#{@parent}/a/bin:#{@parent}/a/sbin:/usr/bin:/bin"
      assert env["AUTONOMOUS_VOLUME_PATH"] == "#{@parent}/a/bin:#{@parent}/a/sbin"
    end

    test "AUTONOMOUS_VOLUMES is the version 1 applied set", ctx do
      {path, 0, out} =
        plan!(ctx, """
        [[volume]]
        name = "a"
        path = "#{@parent}/a"
        env = { X = "1" }
        path_dirs = ["#{@parent}/a/bin"]
        """)

      raw =
        decode_plan(out)["overlay"]["services"]["console"]["environment"]["AUTONOMOUS_VOLUMES"]

      refute raw =~ " "

      assert Jason.decode!(raw) == %{
               "version" => 1,
               "declaration" => path,
               "volumes" => [
                 %{
                   "name" => "a",
                   "path" => "#{@parent}/a",
                   "env" => [["X", "1"]],
                   "path_dirs" => ["#{@parent}/a/bin"]
                 }
               ]
             }
    end

    test "overriding an image variable yields a notice naming old and new", ctx do
      {_, 0, out} =
        plan!(
          ctx,
          """
          [[volume]]
          name = "mise-data"
          path = "#{@parent}/mise-data"
          env = { MISE_DATA_DIR = "#{@parent}/mise-data" }
          """,
          %{image_env: ["MISE_DATA_DIR=/opt/mise"]}
        )

      assert decode_plan(out)["notices"] == [
               "volume mise-data: MISE_DATA_DIR overrides image value /opt/mise with #{@parent}/mise-data"
             ]
    end

    test "there is no entry-count limit (1, 5, 20)", ctx do
      for n <- [1, 5, 20] do
        toml =
          Enum.map_join(1..n, "\n", fn i ->
            "[[volume]]\nname = \"v#{i}\"\npath = \"#{@parent}/v#{i}\"\n"
          end)

        {_, 0, out} = plan!(ctx, toml)
        assert length(decode_plan(out)["volumes"]) == n
      end
    end

    test "--write-overlay writes the overlay atomically with mode 0600", ctx do
      path =
        write_declaration(ctx, "[[volume]]\nname = \"a\"\npath = \"#{@parent}/a\"\n")

      target = Path.join(Path.dirname(path), "applied.compose.json")

      assert {_, 0} =
               run_volumes(
                 [
                   "plan",
                   "--declaration",
                   path,
                   "--context",
                   ctx_json(ctx),
                   "--write-overlay",
                   target
                 ],
                 ctx
               )

      assert %{"services" => %{"dev" => _}} = target |> File.read!() |> Jason.decode!()
      assert File.stat!(target).mode |> Bitwise.band(0o777) == 0o600
      assert Path.wildcard(target <> ".tmp.*") == []
    end

    test "zero entries produce no overlay", ctx do
      {_, 0, out} = plan!(ctx, "# nothing\n")
      plan = decode_plan(out)
      assert plan["volumes"] == []
      refute Map.has_key?(plan, "overlay")
    end
  end

  describe "init" do
    test "writes a comment-only starter, mode 0600, dir 0700", ctx do
      path = declaration_path(ctx)
      assert {out, 0} = run_volumes(["init", "--declaration", path], ctx)
      assert out =~ path

      text = File.read!(path)
      assert {:ok, []} = parse_text(text)
      assert text =~ "AUTONOMOUS_*"
      assert text =~ "ANTHROPIC_API_KEY"
      for eco <- ["Rust", "Node + pnpm", "Elixir", "Python"], do: assert(text =~ eco)

      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
    end

    test "a second init refuses and leaves the file byte-identical", ctx do
      path = write_declaration(ctx, "# mine\n")
      assert {out, 1} = run_volumes(["init", "--declaration", path], ctx)
      assert out =~ "already exists; not changed"
      assert File.read!(path) == "# mine\n"
    end
  end

  describe "show" do
    defp show(ctx, text, present) do
      path = if text, do: write_declaration(ctx, text), else: declaration_path(ctx)

      run_volumes(
        [
          "show",
          "--declaration",
          path,
          "--context",
          ctx_json(ctx),
          "--present",
          Jason.encode!(present)
        ],
        ctx
      )
    end

    test "lists entries as present, absent and kept-not-declared", ctx do
      text = """
      [[volume]]
      name = "cargo-target"
      path = "#{@parent}/cargo-target"
      env = { CARGO_TARGET_DIR = "#{@parent}/cargo-target" }

      [[volume]]
      name = "other"
      path = "#{@parent}/other"
      """

      assert {out, 0} =
               show(ctx, text, [
                 "autonomous-t-1a2b_vol-cargo-target",
                 "autonomous-t-1a2b_vol-old-cache"
               ])

      assert out =~ "volume cargo-target  #{@parent}/cargo-target  present"
      assert out =~ "CARGO_TARGET_DIR=#{@parent}/cargo-target"
      assert out =~ "volume other  #{@parent}/other  absent"

      assert out =~
               "volume old-cache  kept, not declared — remove with: docker volume rm autonomous-t-1a2b_vol-old-cache"

      assert out =~ "declaration valid (2 volumes)"
    end

    test "an absent declaration is reported with how to create one", ctx do
      assert {out, 0} = show(ctx, nil, [])
      assert out =~ "no declaration (create one with --init)"
    end
  end

  describe "validate" do
    defp violations(ctx, text) do
      {_, status, out} = plan!(ctx, text)
      {status, out}
    end

    defp entry(fields) do
      body = Enum.map_join(fields, "\n", fn {k, v} -> "#{k} = #{v}" end)
      "[[volume]]\n" <> body <> "\n"
    end

    defp ok_entry(name, extra \\ []) do
      entry([{"name", ~s("#{name}")}, {"path", ~s("#{@parent}/#{name}")}] ++ extra)
    end

    defp refused(ctx, text, expected) do
      assert {2, out} = violations(ctx, text)
      assert out =~ "nothing was started; fix the declaration and retry"
      assert out =~ expected
      out
    end

    test "a valid declaration passes", ctx do
      assert {0, _} = violations(ctx, ok_entry("a") <> ok_entry("b"))
    end

    test "duplicate name", ctx do
      refused(ctx, ok_entry("a") <> ok_entry("a"), "entry a: name is declared more than once")
    end

    test "non-slug names", ctx do
      for bad <- ["Cargo Target", "a/b", "Upper", "-lead", String.duplicate("a", 64)] do
        text = entry([{"name", ~s("#{bad}")}, {"path", ~s("#{@parent}/x")}])
        refused(ctx, text, "entry #1: name")
      end
    end

    test "relative and non-normalized paths", ctx do
      refused(
        ctx,
        entry([{"name", ~s("a")}, {"path", ~s("cache")}]),
        "entry a: path cache is not absolute"
      )

      for bad <- ["#{@parent}/../x", "#{@parent}//x", "#{@parent}/x/", "#{@parent}/./x"] do
        refused(ctx, entry([{"name", ~s("a")}, {"path", ~s("#{bad}")}]), "is not normalized")
      end
    end

    test "forbidden path characters", ctx do
      for bad <- ["#{@parent}/a:b", "#{@parent}/a,b", "#{@parent}/a\\nb"] do
        refused(ctx, entry([{"name", ~s("a")}, {"path", ~s("#{bad}")}]), "forbidden character")
      end
    end

    test "protected paths: equal, inside and parent", ctx do
      protected = [
        ctx.repo,
        ctx.worktree_root,
        ctx.state_root,
        "/workspace",
        "/workspace/_build",
        "/workspace/deps",
        "/app",
        "/home/autonomous/.claude",
        "/home/autonomous/.claude.json",
        "/home/autonomous/.claude.host.json"
      ]

      for p <- protected, bad <- [p, p <> "/inner"] do
        refused(
          ctx,
          entry([{"name", ~s("a")}, {"path", ~s("#{bad}")}]),
          "entry a: path #{bad} is inside #{p}"
        )
      end

      for parent <- ["/", "/home", "/home/autonomous", "/workspace" |> Path.dirname()] do
        refused(
          ctx,
          entry([{"name", ~s("a")}, {"path", ~s("#{parent}")}]),
          "entry a: path #{parent} contains"
        )
      end
    end

    test "equal or nested entry paths", ctx do
      text =
        ok_entry("a") <>
          entry([{"name", ~s("b")}, {"path", ~s("#{@parent}/a/inner")}])

      refused(ctx, text, "entries a, b: nested paths")

      refused(
        ctx,
        ok_entry("a") <> entry([{"name", ~s("b")}, {"path", ~s("#{@parent}/a")}]),
        "entries a, b: the same path"
      )
    end

    test "reserved variables, every class", ctx do
      for var <- [
            "AUTONOMOUS_X",
            "RELEASE_COOKIE",
            "PATH",
            "HOME",
            "SHELL",
            "USER",
            "MIX_ENV",
            "GH_TOKEN",
            "CLAUDE_CONFIG_DIR",
            "MISE_YES"
          ] do
        refused(
          ctx,
          ok_entry("a", [{"env", ~s({ #{var} = "x" })}]),
          "entry a: #{var} is reserved"
        )
      end
    end

    test "invalid variable names and values", ctx do
      refused(ctx, ok_entry("a", [{"env", ~s({ "1BAD" = "x" })}]), "variable name")
      refused(ctx, ok_entry("a", [{"env", ~s({ GOOD = 5 })}]), "GOOD must be a string")
      refused(ctx, ok_entry("a", [{"env", ~s({ GOOD = "a\\nb" })}]), "GOOD must be a string")
    end

    test "two entries setting one variable", ctx do
      text =
        ok_entry("a", [{"env", ~s({ CARGO_HOME = "x" })}]) <>
          ok_entry("b", [{"env", ~s({ CARGO_HOME = "y" })}])

      refused(ctx, text, "entries a, b: both set CARGO_HOME")
    end

    test "path dirs must be absolute and inside the entry's own path", ctx do
      refused(ctx, ok_entry("a", [{"path_dirs", ~s(["bin"])}]), "path_dirs entry")

      refused(
        ctx,
        ok_entry("a", [{"path_dirs", ~s(["#{@parent}/b/bin"])}]),
        "is outside the entry's own path"
      )

      assert {0, _} = violations(ctx, ok_entry("a", [{"path_dirs", ~s(["#{@parent}/a/bin"])}]))
    end

    test "unknown keys", ctx do
      refused(ctx, ok_entry("a", [{"size", "5"}]), "entry a: unknown key 'size'")
    end

    test "all violations are reported together", ctx do
      text =
        entry([{"name", ~s("Bad")}, {"path", ~s("rel")}]) <>
          ok_entry("b", [{"env", ~s({ PATH = "x" })}])

      out = refused(ctx, text, "3 problems")
      assert out =~ "entry #1: name"
      assert out =~ "entry #1: path"
      assert out =~ "entry b: PATH is reserved"
    end

    test "image-set variables may be overridden", ctx do
      for var <- ["MISE_DATA_DIR", "MIX_HOME", "HEX_HOME", "PLAYWRIGHT_BROWSERS_PATH"] do
        assert {0, _} = violations(ctx, ok_entry("a", [{"env", ~s({ #{var} = "#{@parent}/a" })}]))
      end
    end

    test "start-sequence variables are reserved or explicitly allowed (drift guard)", _ctx do
      root = Path.expand("../..", __DIR__)
      entrypoint = File.read!(Path.join(root, "scripts/container-entrypoint.sh"))
      compose = File.read!(Path.join(root, "compose.yaml"))

      exported =
        Regex.scan(~r/^\s*export\s+([A-Z][A-Z0-9_]*)\b/m, entrypoint, capture: :all_but_first)

      # `environment:` blocks only (build args are not container variables).
      env_keys =
        compose
        |> String.split("\n")
        |> Enum.reduce({nil, []}, fn line, {indent, acc} ->
          lead = byte_size(line) - byte_size(String.trim_leading(line))

          cond do
            String.trim(line) == "environment: &instance-env" or
                String.trim(line) == "environment:" ->
              {lead, acc}

            indent != nil and String.trim(line) != "" and lead <= indent ->
              {nil, acc}

            indent != nil ->
              case Regex.run(~r/^\s+([A-Z][A-Z0-9_]*):/, line, capture: :all_but_first) do
                [key] -> {indent, [key | acc]}
                _ -> {indent, acc}
              end

            true ->
              {nil, acc}
          end
        end)
        |> elem(1)

      names = (List.flatten(exported) ++ env_keys) |> Enum.uniq()
      assert names != []

      {out, 0} =
        System.cmd(
          "python3",
          [
            "-I",
            "-c",
            """
            import importlib.util, json, sys
            spec = importlib.util.spec_from_file_location("volumes", sys.argv[1])
            m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            print(json.dumps([n for n in json.loads(sys.argv[2]) if not (
                n.startswith(m.RESERVED_PREFIXES) or n in m.RESERVED_VARIABLES
                or n in m.ALLOWED_IMAGE_OVERRIDES)]))
            """,
            Path.join(root, "scripts/volumes.py"),
            Jason.encode!(names)
          ]
        )

      missing = Jason.decode!(out)

      assert missing == [],
             "start-sequence variables missing from volumes.py RESERVED_* / ALLOWED_IMAGE_OVERRIDES: #{inspect(missing)}"
    end
  end

  describe "select" do
    @two """
    [[volume]]
    name = "a"
    path = "#{@parent}/a"

    [[volume]]
    name = "b"
    path = "#{@parent}/b"
    """

    defp select(ctx, text, names) do
      path = write_declaration(ctx, text)
      args = Enum.flat_map(names, &["--volume", &1])
      run_volumes(["select", "--declaration", path | args], ctx)
    end

    test "no names selects every declared volume in order", ctx do
      assert {"a\nb\n", 0} = select(ctx, @two, [])
    end

    test "a named subset keeps declaration order", ctx do
      assert {"a\nb\n", 0} = select(ctx, @two, ["b", "a"])
      assert {"b\n", 0} = select(ctx, @two, ["b"])
    end

    test "an unknown name lists the declared names", ctx do
      assert {out, 2} = select(ctx, @two, ["x"])
      assert out =~ "volume x is not declared; declared: a, b"
    end

    test "mount-path and variable violations do not block selection", ctx do
      text = """
      [[volume]]
      name = "a"
      path = "/workspace/x"
      env = { PATH = "x" }
      """

      assert {"a\n", 0} = select(ctx, text, [])
    end

    test "malformed file and invalid names block selection", ctx do
      assert {out, 2} = select(ctx, "[[volume]\n", [])
      assert out =~ "not valid TOML"
      assert {out, 2} = select(ctx, "[[volume]]\nname = \"Bad Name\"\npath = \"/x\"\n", [])
      assert out =~ "lowercase slug"
    end

    test "zero entries select nothing", ctx do
      assert {"", 0} = select(ctx, "# none\n", [])
    end
  end
end
