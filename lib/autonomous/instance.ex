defmodule Autonomous.Instance do
  @moduledoc """
  Per-target instance identity (feature 031, FR-007/FR-018/FR-018a).

  A container serves exactly one target repository. Everything that must exist
  before the VM starts — node name, store directory, lock, cookie — derives
  from the target's `RepoIdentity` partition and the shared state root, in one
  place (`derive/3`). Shell never recomputes it; the entrypoint asks
  `mix autonomous.instance` (or release `eval`), and the app re-verifies at boot.

  `derive/3`, `verify/2` and `served?/2` are pure. `current/0`, `verify!/0`
  and `assert_served!/1` are the IO wrappers, and all of them are no-ops unless
  `Autonomous.ContainerGuard.containerized?/0`. See
  `specs/031-containerized-runtime/contracts/{instance-identity,boot-guard}.md`.
  """

  alias Autonomous.{Config, ContainerGuard, RepoIdentity}

  defmodule NotServedError do
    @moduledoc "Raised when a facade call names a repository this instance does not serve."
    defexception [:served, :given, :message]

    @impl true
    def exception(opts) do
      served = Keyword.fetch!(opts, :served)
      given = Keyword.fetch!(opts, :given)

      %__MODULE__{
        served: served,
        given: given,
        message:
          "this instance serves #{served}; #{given} is not served here. " <>
            "Start another instance with scripts/autonomous shell --target #{given}."
      }
    end
  end

  @enforce_keys [:repo, :partition, :segment, :node_name, :store_dir, :lock_path, :owner_path, :cookie_path, :worktree_root]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          repo: String.t(),
          partition: String.t(),
          segment: String.t(),
          node_name: atom(),
          store_dir: String.t(),
          lock_path: String.t(),
          owner_path: String.t(),
          cookie_path: String.t(),
          worktree_root: String.t()
        }

  @typedoc "What the running VM actually has, compared against the derivation."
  @type actual :: %{
          optional(:locked) => String.t() | nil,
          optional(:node) => atom(),
          optional(:store_dir) => String.t()
        }

  @host "autonomous"
  @served_override :autonomous_instance_served_override

  # ---- pure derivation -------------------------------------------------------

  @doc "Pure derivation from `(repo, partition, state_root)`."
  @spec derive(repo :: String.t(), partition :: String.t(), state_root :: String.t()) :: t()
  def derive(repo, partition, state_root)
      when is_binary(repo) and is_binary(partition) and is_binary(state_root) do
    segment =
      partition
      |> String.replace_prefix("o:", "")
      |> String.replace_prefix("l:", "")

    base = Path.join([state_root, "instances", segment])

    %__MODULE__{
      repo: repo,
      partition: partition,
      segment: segment,
      node_name: String.to_atom("autonomous_#{sanitize(segment)}@#{@host}"),
      store_dir: Path.join(base, "mnesia"),
      lock_path: Path.join(base, "instance.lock"),
      owner_path: Path.join(base, "instance.json"),
      cookie_path: Path.join(base, "cookie"),
      worktree_root: Autonomous.Layout.worktree_root(state_root, segment)
    }
  end

  defp sanitize(segment), do: String.replace(segment, ~r/[^A-Za-z0-9_-]/u, "_")

  @doc "The identity of the configured target (IO: reads the target's `origin`)."
  @spec current() :: t()
  def current do
    repo = Config.repo() |> Path.expand()
    derive(repo, RepoIdentity.partition(repo), Config.autonomous_root())
  end

  @doc """
  Print the six `AUTONOMOUS_*` identity variables as `KEY=value` lines — the
  release `eval` entry point (`bin/autonomous eval 'Autonomous.Instance.print_env()'`).
  """
  @spec print_env() :: :ok
  def print_env, do: current() |> env_lines() |> Enum.each(&IO.puts/1)

  @doc "`KEY=value` lines for the identity variables (contracts/environment.md)."
  @spec env_lines(t()) :: [String.t()]
  def env_lines(%__MODULE__{} = i) do
    [
      "AUTONOMOUS_INSTANCE_SEGMENT=#{i.segment}",
      "AUTONOMOUS_NODE_NAME=#{i.node_name}",
      "AUTONOMOUS_STORE_DIR=#{i.store_dir}",
      "AUTONOMOUS_COOKIE_PATH=#{i.cookie_path}",
      "AUTONOMOUS_INSTANCE_LOCK=#{i.lock_path}",
      "AUTONOMOUS_WORKTREE_ROOT=#{i.worktree_root}"
    ]
  end

  # ---- boot verification -----------------------------------------------------

  @doc """
  Pure check of the running VM against the derived identity, in the contract
  order: lock, node, store directory.
  """
  @spec verify(actual(), t()) :: :ok | {:error, term()}
  def verify(actual, %__MODULE__{} = i) when is_map(actual) do
    cond do
      Map.get(actual, :locked) != i.lock_path ->
        {:error, {:instance_unlocked, i.lock_path}}

      Map.get(actual, :node) != i.node_name ->
        {:error, {:instance_mismatch, :node, i.node_name, Map.get(actual, :node)}}

      Map.get(actual, :store_dir) != i.store_dir ->
        {:error, {:instance_mismatch, :store_dir, i.store_dir, Map.get(actual, :store_dir)}}

      true ->
        :ok
    end
  end

  @doc "Raises `RuntimeError` when `verify/2` refuses. No-op outside container mode."
  @spec verify!() :: :ok
  def verify! do
    if ContainerGuard.containerized?() do
      actual = %{
        locked: System.get_env("AUTONOMOUS_INSTANCE_LOCKED"),
        node: node(),
        store_dir: Config.store_dir()
      }

      case verify(actual, current()) do
        :ok -> :ok
        {:error, term} -> raise "#{inspect(term)}: #{describe(term)}"
      end
    else
      :ok
    end
  end

  defp describe({:instance_unlocked, lock_path}),
    do: "instance lock #{lock_path} is not held; start through scripts/autonomous"

  defp describe({:instance_mismatch, :node, expected, actual}),
    do:
      "expected node #{expected} but running as #{actual}; " <>
        "do not pass an ad hoc --sname, start through scripts/autonomous"

  defp describe({:instance_mismatch, :store_dir, expected, actual}),
    do: "expected store directory #{expected} but configured #{actual}"

  # ---- served-repository guard (FR-007) ---------------------------------------

  @doc """
  Pure: does `identity` serve `given`? `given` is a repository path or a
  partition string (`"o:…"`/`"l:…"`). A path is resolved through `partition_fun`
  (default `RepoIdentity.partition/1`, which reads git).
  """
  @spec served?(t(), String.t(), (String.t() -> String.t())) :: boolean()
  def served?(%__MODULE__{} = identity, given, partition_fun \\ &RepoIdentity.partition/1)
      when is_binary(given) do
    partition =
      if String.starts_with?(given, ["o:", "l:"]), do: given, else: partition_fun.(Path.expand(given))

    partition == identity.partition
  end

  @doc """
  Raises `NotServedError` when this instance does not serve `given`. No-op
  outside container mode.
  """
  @spec assert_served!(String.t()) :: :ok
  def assert_served!(given) when is_binary(given) do
    case served_identity() do
      nil ->
        :ok

      identity ->
        if served?(identity, given) do
          :ok
        else
          raise NotServedError, served: identity.repo, given: given
        end
    end
  end

  # The identity this process must serve, or nil outside container mode.
  # Test seam: `with_served/2` injects an identity for the calling process so
  # container-mode behaviour is testable without flipping global config.
  defp served_identity do
    case Process.get(@served_override) do
      %__MODULE__{} = injected -> injected
      nil -> if ContainerGuard.containerized?(), do: current(), else: nil
    end
  end

  @doc """
  Test seam: run `fun` with `identity` as the served identity of the calling
  process, as if container mode were on. Not used by production code.
  """
  @spec with_served(t(), (-> result)) :: result when result: term()
  def with_served(%__MODULE__{} = identity, fun) when is_function(fun, 0) do
    previous = Process.put(@served_override, identity)

    try do
      fun.()
    after
      if previous, do: Process.put(@served_override, previous), else: Process.delete(@served_override)
    end
  end
end
