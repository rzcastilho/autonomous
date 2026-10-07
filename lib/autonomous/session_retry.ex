defmodule Autonomous.SessionRetry do
  @moduledoc """
  Pure retry decision for the sites that drive a harness session without going
  through `PhaseStep` — auto-remediation (`AnalyzeRunner`) and the pre-phase
  remediation step (`FeatureRunner`) (feature 034).

  A session that died (`signals.session_died`, set by the action classifiers)
  earns exactly one fresh session — unless the run's breaker is tripped or a
  drain was requested, in which case no new session may start (drain, don't
  kill; FR-010). Every other outcome is accepted as it stands.
  """

  @type opts :: %{
          required(:retried?) => boolean(),
          required(:breaker?) => boolean(),
          required(:drain?) => boolean()
        }

  @doc """
  `:retry` when `last_signals` carries a session death and this is the first
  one at the site; `:accept` otherwise.
  """
  @spec once(map() | nil, opts()) :: :retry | :accept
  def once(last_signals, %{retried?: retried?, breaker?: breaker?, drain?: drain?}) do
    died? = is_map(last_signals) and is_map(Map.get(last_signals, :session_died))

    if died? and not retried? and not breaker? and not drain?, do: :retry, else: :accept
  end
end
