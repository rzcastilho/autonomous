defmodule Autonomous.StubDocker do
  @moduledoc """
  PATH shim standing in for `docker` (feature 041), following the pattern in
  `container_build_options_test.exs`.

  Every call is appended to a log (`args=<argv>`). `volume inspect/create/rm`,
  `ps -a`, `image inspect` and `run` are scripted through `opts`:

    * `:volumes`  - existing volume names (`volume inspect` succeeds for these)
    * `:labels`   - `%{volume_name => "k=v,k=v"}` returned by `volume inspect --format`
    * `:containers` - lines printed by `ps -a`
    * `:image`    - `false` makes `image inspect` fail (default succeeds)
    * `:run_exit` - exit status of `run` (default 0)
    * `:segment`  - instance segment printed for `compose ... identity` (default `t-1a2b`)
    * `:image_env` - JSON printed for `image inspect -f` (default none)
    * `:ls`       - lines printed for `volume ls`

  Feature 046 (container engine sidecar) adds, all defaulting to "healthy engine":

    * `:compose_version` - printed by `compose version --short` (default `2.30.0`)
    * `:missing_images`  - image names for which `image inspect` fails
    * `:client`          - exit status of the in-image client check
                           (`run ... command -v docker ...`), default 0
    * `:engine_up`       - `{exit, output}` of `compose ... up ... engine` (default `{0, ""}`)
    * `:engine_logs`     - printed by `compose ... logs ... engine`
    * `:agent_exit`      - exit code the agent container reports once started; makes
                           `compose ps -aq` / `inspect` / `logs` describe an exited
                           container so `wait_for_console` returns instead of polling
    * `:agent_logs`      - printed by the agent's `compose ... logs`
    * `:published`       - `%{container_id => "host:port"}` printed by `docker port`
    * `:engine_ps`       - lines printed by `ps -a --filter ... service=engine`
                           (the sidecar-detection query of `stop`)
  """

  @doc "Installs the stub under `base`; returns `%{bin: dir, log: path}`."
  def install(base, opts \\ []) do
    bin = Path.join(base, "bin")
    state = Path.join(base, "docker_state")
    log = Path.join(base, "docker.log")
    File.mkdir_p!(bin)
    File.mkdir_p!(state)

    Enum.each(Keyword.get(opts, :volumes, []), &File.write!(Path.join(state, "vol-" <> &1), ""))

    for {name, labels} <- Keyword.get(opts, :labels, %{}) do
      File.write!(Path.join(state, "labels-" <> name), labels)
    end

    File.write!(
      Path.join(state, "containers"),
      Enum.join(Keyword.get(opts, :containers, []), "\n")
    )

    image_exit = if Keyword.get(opts, :image, true), do: 0, else: 1
    run_exit = Keyword.get(opts, :run_exit, 0)
    segment = Keyword.get(opts, :segment, "t-1a2b")
    File.write!(Path.join(state, "image_env"), Keyword.get(opts, :image_env, ""))
    File.write!(Path.join(state, "ls"), Enum.join(Keyword.get(opts, :ls, []), "\n"))

    compose_version = Keyword.get(opts, :compose_version, "2.30.0")
    client_exit = Keyword.get(opts, :client, 0)
    {up_rc, up_out} = Keyword.get(opts, :engine_up, {0, ""})

    File.write!(
      Path.join(state, "missing_images"),
      Enum.join(Keyword.get(opts, :missing_images, []), "\n")
    )

    File.write!(Path.join(state, "engine_up_out"), up_out)
    File.write!(Path.join(state, "engine_logs"), Keyword.get(opts, :engine_logs, ""))
    File.write!(Path.join(state, "agent_logs"), Keyword.get(opts, :agent_logs, ""))
    File.write!(Path.join(state, "engine_ps"), Enum.join(Keyword.get(opts, :engine_ps, []), "\n"))

    case Keyword.get(opts, :agent_exit) do
      nil -> :ok
      code -> File.write!(Path.join(state, "agent_exit"), to_string(code))
    end

    for {cid, mapping} <- Keyword.get(opts, :published, %{}) do
      File.write!(Path.join(state, "port-" <> cid), mapping)
    end

    stub = Path.join(bin, "docker")

    File.write!(stub, """
    #!/bin/sh
    if [ "$1 $2 $3" = "compose version --short" ]; then echo #{compose_version}; exit 0; fi
    echo "args=$*" >> "#{log}"
    echo "env WITH_DOCKER=[${WITH_DOCKER:-}] SEGMENT=[${AUTONOMOUS_INSTANCE_SEGMENT:-}]" >> "#{log}"
    state="#{state}"
    case "$1 $2" in
      "volume inspect")
        shift 2
        name=""
        for a in "$@"; do name="$a"; done
        [ -e "$state/vol-$name" ] || exit 1
        [ -e "$state/labels-$name" ] && cat "$state/labels-$name"
        exit 0 ;;
      "volume create") exit 0 ;;
      "volume rm") exit 0 ;;
      "image inspect")
        for a in "$@"; do last="$a"; done
        grep -qxF "$last" "$state/missing_images" && exit 1
        case "$*" in *"-f"*) cat "$state/image_env" ;; esac
        exit #{image_exit} ;;
      "volume ls") cat "$state/ls"; exit 0 ;;
    esac
    case "$*" in
      *"command -v docker"*) exit #{client_exit} ;;
    esac
    case "$1" in
      compose)
        case "$*" in
          *" up -d "*" engine")
            cat "$state/engine_up_out"; exit #{up_rc} ;;
          *" logs "*" engine") cat "$state/engine_logs"; exit 0 ;;
          *" logs "*) cat "$state/agent_logs"; exit 0 ;;
          *" ps -aq "*)
            [ -e "$state/agent_exit" ] && echo cid-agent
            exit 0 ;;
          *" identity")
            echo "AUTONOMOUS_INSTANCE_SEGMENT=#{segment}"
            echo "AUTONOMOUS_NODE_NAME=autonomous_#{segment}"
            echo "AUTONOMOUS_WORKTREE_ROOT=/home/autonomous/.autonomous/worktrees/#{segment}"
            exit 0 ;;
        esac
        exit 0 ;;
      ps)
        case "$*" in
          *"service=engine"*) cat "$state/engine_ps"; exit 0 ;;
        esac
        cat "$state/containers"; exit 0 ;;
      inspect)
        [ -e "$state/agent_exit" ] && echo "exited $(cat "$state/agent_exit")"
        exit 0 ;;
      port)
        [ -e "$state/port-$2" ] || exit 1
        cat "$state/port-$2"; exit 0 ;;
      run) exit #{run_exit} ;;
    esac
    exit 0
    """)

    File.chmod!(stub, 0o755)
    %{bin: bin, log: log}
  end

  @doc "Recorded docker calls, or `\"\"` when none (includes the `env ...` lines of feature 046)."
  def calls(%{log: log}), do: if(File.exists?(log), do: File.read!(log), else: "")

  @doc "Just the argv of each recorded call, oldest first (the `args=` lines, prefix removed)."
  def argvs(ctx) do
    for "args=" <> argv <- String.split(calls(ctx), "\n"), do: argv
  end
end
