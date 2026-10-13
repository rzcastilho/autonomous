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

    File.write!(Path.join(state, "containers"), Enum.join(Keyword.get(opts, :containers, []), "\n"))

    image_exit = if Keyword.get(opts, :image, true), do: 0, else: 1
    run_exit = Keyword.get(opts, :run_exit, 0)
    segment = Keyword.get(opts, :segment, "t-1a2b")
    File.write!(Path.join(state, "image_env"), Keyword.get(opts, :image_env, ""))
    File.write!(Path.join(state, "ls"), Enum.join(Keyword.get(opts, :ls, []), "\n"))

    stub = Path.join(bin, "docker")

    File.write!(stub, """
    #!/bin/sh
    if [ "$1 $2 $3" = "compose version --short" ]; then echo 2.30.0; exit 0; fi
    echo "args=$*" >> "#{log}"
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
        case "$*" in *"-f"*) cat "$state/image_env" ;; esac
        exit #{image_exit} ;;
      "volume ls") cat "$state/ls"; exit 0 ;;
    esac
    case "$1" in
      compose)
        case "$*" in
          *" identity")
            echo "AUTONOMOUS_INSTANCE_SEGMENT=#{segment}"
            echo "AUTONOMOUS_NODE_NAME=autonomous_#{segment}"
            echo "AUTONOMOUS_WORKTREE_ROOT=/home/autonomous/.autonomous/worktrees/#{segment}"
            exit 0 ;;
        esac
        exit 0 ;;
      ps) cat "$state/containers"; exit 0 ;;
      run) exit #{run_exit} ;;
    esac
    exit 0
    """)

    File.chmod!(stub, 0o755)
    %{bin: bin, log: log}
  end

  @doc "Recorded docker calls, or `\"\"` when none."
  def calls(%{log: log}), do: if(File.exists?(log), do: File.read!(log), else: "")
end
