defmodule SpeckitOrchestrator.Boot do
  @moduledoc """
  Idle-by-default supervised child (FR-029..FR-031, research.md §R11).

  Its work happens in `handle_continue/2` so it never blocks its supervisor's
  `init/1` (Constitution VI, "no blocking the scheduler"): it runs
  `Preflight.run/1`, and — only when the report is `:pass`/`:warn` **and**
  `AUTONOMOUS_AUTOSTART` names a run — launches it via the facade. A `:fail`
  report logs and leaves the container idle: no run starts, and no success is
  reported (FR-031). `Boot` never stops the VM itself; the container stays up
  after a launched run drains (FR-030) until the operator stops it.

  ## Shutdown flush (FR-027, container isolation)

  `Boot` is the one component in this chain that is genuinely supervised
  (a normal child of `SpeckitOrchestrator.Application`'s top supervisor), so
  it is also the one that traps exits: on a container's `docker stop`
  (`SIGTERM` → `init:stop`), the supervisor's own shutdown signal reliably
  reaches `Boot`'s `terminate/2` regardless of `trap_exit`. From there it
  explicitly `GenServer.stop/1`s `:coordinator_name` (if a run is
  registered) and then `:ledger_name` — the ordinary `GenServer.stop/1`
  protocol always invokes their `terminate/2` regardless of *their*
  `trap_exit`, so neither `Coordinator` nor `Ledger` needs to trap exits
  itself. `Coordinator` is stopped first so its flush can still read
  `Ledger`'s spend while it's alive.

  These two names are `nil` by default — a deliberate opt-in
  (`SpeckitOrchestrator.Application` passes the real
  `SpeckitOrchestrator.Coordinator`/`SpeckitOrchestrator.Ledger` names) so
  that a `Boot` started directly by a test (there are several, none of which
  intend to touch the shared app-supervised `Ledger`) is a shutdown no-op by
  default.
  """

  use GenServer

  require Logger

  alias SpeckitOrchestrator.Container.Env
  alias SpeckitOrchestrator.Preflight

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, opts, {:continue, :boot}}
  end

  @impl true
  def terminate(_reason, opts) do
    stop_if_alive(Keyword.get(opts, :coordinator_name))
    stop_if_alive(Keyword.get(opts, :ledger_name))
    :ok
  end

  defp stop_if_alive(nil), do: :ok

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_continue(:boot, opts) do
    env = Keyword.get_lazy(opts, :env, &Env.load!/0)
    preflight_opts = Keyword.get(opts, :preflight_opts, [])
    runner = Keyword.get(opts, :runner, &SpeckitOrchestrator.run/1)

    case Preflight.run(preflight_opts) do
      {:ok, _report} ->
        autostart(env.autostart, runner)

      {:error, report} ->
        Logger.error(
          "preflight failed — staying idle, no run started, no success reported: " <>
            "#{inspect(failing_ids(report))}"
        )
    end

    {:noreply, opts}
  end

  defp autostart(:none, _runner), do: :ok

  defp autostart(:ad_hoc, runner) do
    Logger.info("AUTONOMOUS_AUTOSTART=ad-hoc — launching the ad-hoc run")
    runner.(scope: :ad_hoc)
  end

  defp autostart({:breakdown, slug}, runner) do
    Logger.info("AUTONOMOUS_AUTOSTART=#{slug} — launching the breakdown run")
    runner.(slug: slug)
  end

  defp failing_ids(report) do
    report.checks
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map(& &1.id)
  end
end
