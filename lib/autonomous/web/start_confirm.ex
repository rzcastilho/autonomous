defmodule Autonomous.Web.StartConfirm do
  @moduledoc """
  Pure state machine behind Trigger Run's two-step start (033, data-model §3,
  research R10). `Autonomous.run/1` drains and supersedes any in-flight run, so
  when one exists the first click only *arms* the button; the second click on
  the same run dispatches. With no run in flight, one click dispatches.

  Never starts against a run the operator has not seen: a click that finds a
  different run than the one armed re-arms on the new one.
  """

  @type state :: :idle | {:armed, String.t()}
  @type event :: :click | :cancel | {:active_run, String.t() | nil} | :tab_switch
  @type effect :: :dispatch | :none

  @doc "`next(state, event, active_run_id)` — `active_run_id` is the server's value at the time of the event."
  @spec next(state(), event(), String.t() | nil) :: {state(), effect()}
  def next(:idle, :click, nil), do: {:idle, :dispatch}
  def next(:idle, :click, run_id), do: {{:armed, run_id}, :none}

  def next({:armed, run_id}, :click, run_id), do: {:idle, :dispatch}
  def next({:armed, _armed}, :click, nil), do: {:idle, :dispatch}
  def next({:armed, _armed}, :click, other), do: {{:armed, other}, :none}

  def next(_state, :cancel, _active), do: {:idle, :none}
  def next(_state, :tab_switch, _active), do: {:idle, :none}

  def next({:armed, _armed}, {:active_run, nil}, _active), do: {:idle, :none}
  def next({:armed, _armed}, {:active_run, other}, _active), do: {{:armed, other}, :none}
  def next(:idle, {:active_run, _run_id}, _active), do: {:idle, :none}
end
