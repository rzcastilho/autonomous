defmodule Autonomous.ShellTimeouts do
  @moduledoc """
  Pure derivation of the Bash tool timeouts (`BASH_DEFAULT_TIMEOUT_MS` /
  `BASH_MAX_TIMEOUT_MS`) for one headless session from that session's own
  wall-clock deadline (feature 032, FR-006–FR-008).

  The CLI's built-in cap is 10 minutes; a longer foreground command is moved to
  the background, and a headless session that then ends its turn is lost. The
  shell cap is raised to `deadline - 5 min` (max 45 min) so a foreground command
  can finish, while `PhaseSession.reduce/2`'s deadline still always fires first.

  A deadline of 10 minutes or less pins the CLI built-ins: there is no room to
  raise the cap without exceeding the session.
  """

  @cli_default_ms 120_000
  @cli_max_ms 600_000
  @floor_ms 600_000
  @headroom_ms 300_000
  @max_cap_ms 2_700_000
  @default_cap_ms 1_800_000

  @spec for_deadline(pos_integer()) :: %{String.t() => String.t()}
  def for_deadline(deadline_ms) when is_integer(deadline_ms) and deadline_ms > @floor_ms do
    max = min(@max_cap_ms, deadline_ms - @headroom_ms)
    default = min(@default_cap_ms, max)
    build(default, max)
  end

  def for_deadline(deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0,
    do: build(@cli_default_ms, @cli_max_ms)

  defp build(default, max) do
    %{
      "BASH_DEFAULT_TIMEOUT_MS" => Integer.to_string(default),
      "BASH_MAX_TIMEOUT_MS" => Integer.to_string(max)
    }
  end
end
