defmodule Autonomous.ContainerEngineGuardTest do
  # Mechanical guard for the Principle III boundary of the engine sidecar (feature 046,
  # FR-004..007): the host engine socket is never mounted, only `engine` is privileged,
  # the engine endpoint is never published, and engine storage is project-scoped.
  # Text-level on purpose — no YAML parser is a dependency, and the overlays are small.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @agents ~w(dev console release)

  defp read(path), do: File.read!(Path.join(@root, path))

  defp strip_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map(&Regex.replace(~r/(^|\s)#.*$/, &1, ""))
    |> Enum.join("\n")
  end

  # A top-level key's block: its lines up to the next top-level key.
  defp top_block(text, key) do
    lines = String.split(strip_comments(text), "\n")

    lines
    |> Enum.drop_while(&(&1 != "#{key}:"))
    |> case do
      [] -> []
      [_ | rest] -> Enum.take_while(rest, &(&1 == "" or String.starts_with?(&1, " ")))
    end
  end

  # Services under `services:` as %{name => lines}.
  defp services(text) do
    text
    |> top_block("services")
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        case Regex.run(~r/^  ([A-Za-z0-9_-]+):\s*(.*)$/, line) do
          [_, name, _] ->
            case acc do
              nil -> {:cont, {name, []}}
              done -> {:cont, done, {name, []}}
            end

          _ ->
            case acc do
              nil -> {:cont, nil}
              {name, ls} -> {:cont, {name, [line | ls]}}
            end
        end
      end,
      fn
        nil -> {:cont, nil}
        {name, ls} -> {:cont, {name, ls}, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn {name, ls} -> {name, Enum.reverse(ls)} end)
  end

  defp has_key?(lines, key), do: Enum.any?(lines, &Regex.match?(~r/^\s{4}#{key}:/, &1))

  defp engine_overlay, do: read("compose.engine.yaml")

  describe "no host engine socket" do
    test "no host docker socket is referenced by any compose file, the Dockerfile or any script" do
      files =
        Path.wildcard(Path.join(@root, "compose*.yaml")) ++
          [Path.join(@root, "Dockerfile")] ++
          Path.wildcard(Path.join(@root, "scripts/*"))

      for file <- files, File.regular?(file) do
        body = file |> File.read!() |> strip_comments()

        # The rootless daemon's own socket (`/run/user/<uid>/docker.sock`, inside the
        # sidecar) is fine; the host's `/var/run/docker.sock` and `/run/docker.sock` are not.
        host_socket =
          Regex.scan(~r{(?<!user/\$\{AUTONOMOUS_UID\})(?:/var)?/run/docker\.sock}, body)

        assert host_socket == [],
               "#{Path.relative_to(file, @root)} references the host engine socket"

        mounts =
          Regex.scan(~r/^\s*-\s*["']?[^"'\n]*docker\.sock[^"'\n]*:[^\n]*$/m, body)

        assert mounts == [],
               "#{Path.relative_to(file, @root)} mounts a docker socket: #{inspect(mounts)}"
      end
    end
  end

  describe "agent services gain no privilege" do
    test "dev/console/release carry no privileged, cap_add, devices or security_opt" do
      svcs = services(engine_overlay())

      for name <- @agents do
        lines = Map.fetch!(svcs, name)

        for key <- ~w(privileged cap_add devices security_opt) do
          refute has_key?(lines, key), "#{name} sets #{key} in compose.engine.yaml"
        end
      end
    end

    test "agent services join the sidecar's network namespace and nothing else changes it" do
      svcs = services(engine_overlay())

      for name <- @agents do
        assert Enum.any?(svcs[name], &String.contains?(&1, ~s(network_mode: "service:engine")))
      end
    end

    test "only engine is privileged, in every overlay" do
      for file <- Path.wildcard(Path.join(@root, "compose*.yaml")) do
        svcs = file |> File.read!() |> services()

        for {name, lines} <- svcs, name != "engine" do
          refute Enum.any?(lines, &Regex.match?(~r/^\s{4}privileged:\s*true/, &1)),
                 "#{Path.basename(file)}: #{name} is privileged"
        end
      end

      engine = Map.fetch!(services(engine_overlay()), "engine")
      assert Enum.any?(engine, &Regex.match?(~r/^\s{4}privileged:\s*true/, &1))
    end
  end

  describe "engine endpoint and mounts" do
    test "2375 appears under no ports list" do
      for file <- Path.wildcard(Path.join(@root, "compose*.yaml")),
          {name, lines} <- file |> File.read!() |> services() do
        ports =
          lines
          |> Enum.drop_while(&(not Regex.match?(~r/^\s{4}ports:/, &1)))
          |> Enum.drop(1)
          |> Enum.take_while(&Regex.match?(~r/^\s{6}-/, &1))

        refute Enum.any?(ports, &String.contains?(&1, "2375")),
               "#{Path.basename(file)}: #{name} publishes 2375"
      end
    end

    test "engine mounts only the repo, the state root and its storage volume" do
      engine = Map.fetch!(services(engine_overlay()), "engine")

      mounts =
        engine
        |> Enum.drop_while(&(not Regex.match?(~r/^\s{4}volumes:/, &1)))
        |> Enum.drop(1)
        |> Enum.take_while(&Regex.match?(~r/^\s{6}-/, &1))
        |> Enum.map(&(&1 |> String.replace(~r/^\s*-\s*/, "") |> String.trim("\"")))

      assert Enum.sort(mounts) ==
               Enum.sort([
                 "${AUTONOMOUS_REPO}:${AUTONOMOUS_REPO}",
                 "${AUTONOMOUS_ROOT}:${AUTONOMOUS_ROOT}",
                 "autonomous-engine:/home/rootless/.local/share/docker"
               ])

      for m <- mounts do
        refute String.contains?(m, "/workspace")
        refute String.contains?(m, "$HOME")
        refute String.contains?(m, "~")
      end
    end

    test "the storage volume is project-scoped (no name:) and labelled" do
      block = engine_overlay() |> top_block("volumes")
      joined = Enum.join(block, "\n")

      assert joined =~ "autonomous-engine:"
      refute joined =~ ~r/^\s+name:/m
      assert joined =~ "dev.autonomous.kind: engine-storage"
      assert joined =~ "dev.autonomous.segment:"
    end
  end
end
