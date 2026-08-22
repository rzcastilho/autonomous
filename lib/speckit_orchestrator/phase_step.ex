defmodule SpeckitOrchestrator.PhaseStep do
  @moduledoc """
  Run one phase: `[:speckit, :phase]` telemetry span, transient-retry policy.
  Extracted from `FeatureRunner` (research R8) so `AnalyzeRunner`'s
  attempt-numbered analyze/remediation records can share this exact machinery
  via `:span_meta` without duplicating it.

  Returns the agent so the caller (`FeatureRunner`, `AnalyzeRunner`) can
  persist the attempt/checkpoint/transcript through `Store.Writer` in its own
  boundary transaction (018).
  """

  require Logger

  alias Jido.{AgentServer, Signal}

  alias SpeckitOrchestrator.{Config, Feature, PhaseResult, Pipeline}

  @doc """
  Run `phase` for `feature` via the agent at `pid`, retrying transient
  failures. Options:

    * `:step` (required) — the pipeline step number, for the span meta.
    * `:timeout` (required) — the `AgentServer.call/3` timeout.
    * `:retries` — transient-retry budget (default `Config.phase_max_retries/0`).
    * `:span_meta` — extra keys merged into the `[:speckit, :phase]` span
      meta (e.g. `%{attempt:, limit:}`).
  """
  @spec run(pid(), Feature.t(), Pipeline.phase(), keyword()) :: struct()
  def run(pid, feature, phase, opts) do
    step = Keyword.fetch!(opts, :step)
    timeout = Keyword.fetch!(opts, :timeout)
    retries = Keyword.get(opts, :retries, Config.phase_max_retries())
    span_meta = Keyword.get(opts, :span_meta, %{})

    run_with_retry(pid, feature, phase, step, timeout, span_meta, retries)
  end

  # Re-run a phase that failed transiently (a server/API drop, not a real
  # error) up to `retries` times before giving up. Real errors and most gate
  # outcomes (signals, not `:error`) fall straight through.
  defp run_with_retry(pid, feature, phase, step, timeout, span_meta, retries) do
    agent = run_once(pid, feature, phase, step, timeout, span_meta)
    st = agent.state

    case retries > 0 and retry_reason(st) do
      false ->
        agent

      nil ->
        agent

      reason ->
        Logger.warning(
          "feature #{feature.id} phase #{phase} #{reason} — retrying (#{retries} left)"
        )

        run_with_retry(pid, feature, phase, step, timeout, span_meta, retries - 1)
    end
  end

  # Why this attempt is worth repeating, or `nil` to accept it as final.
  #
  # Beyond the original transient case, two outcomes are retried because both
  # are evidence the model *started* and stopped rather than deliberately
  # refusing, and neither reproduces deterministically — a fresh session is the
  # single most likely thing to fix them:
  #
  #   * `outstanding_work?` — the session reported success with tool calls still
  #     unreturned, i.e. it ended its turn mid-flight.
  #   * `unfilled_artifact?` — the artifact exists but is the untouched Spec Kit
  #     template.
  #
  # A *plain* missing artifact is deliberately NOT retried: a phase that wrote
  # nothing at all usually refused for a deterministic reason (a contradictory
  # `plan_stack` being the common one), so a second session burns the same
  # model for the same refusal.
  defp retry_reason(st) do
    signals = st.last_signals || %{}

    cond do
      st.last_outcome != :error and not Map.get(signals, :unfilled_artifact?, false) -> nil
      PhaseResult.transient?(st.last_result) and st.last_outcome == :error -> "failed transiently"
      Map.get(signals, :outstanding_work?, false) -> "ended with work outstanding"
      Map.get(signals, :unfilled_artifact?, false) -> "left its artifact as an unfilled template"
      true -> nil
    end
  end

  defp run_once(pid, feature, phase, step, timeout, span_meta) do
    meta =
      %{feature_id: feature.id, phase: phase, model: Config.model_for(phase), step: step}
      |> Map.merge(span_meta)

    :telemetry.span([:speckit, :phase], meta, fn ->
      {:ok, agent} = call(pid, "phase.run", %{phase: phase}, timeout)
      entry = List.first(agent.state.history) || %{}
      Logger.info("feature #{feature.id} phase #{phase} -> #{inspect(Map.get(entry, :outcome))}")

      {agent,
       Map.merge(meta, %{outcome: Map.get(entry, :outcome), cost: Map.get(entry, :cost, 0.0)})}
    end)
  end

  defp call(pid, type, data, timeout) do
    AgentServer.call(pid, Signal.new!(type, data, source: "/runner"), timeout)
  end
end
