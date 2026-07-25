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
    {:ok, opts, {:continue, :boot}}
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
