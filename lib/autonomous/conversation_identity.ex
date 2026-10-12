defmodule Autonomous.ConversationIdentity do
  @moduledoc """
  Who a recorded session belongs to (feature 040). Built by `FeatureRunner` for
  each session-driving step; `validate/1` is the loud boundary check
  (`{:error, {:bad_identity, field}}`).
  """

  @enforce_keys [:run_id, :feature_id, :phase, :ordinal, :transcript_root]
  defstruct [
    :repo_id,
    :run_id,
    :feature_id,
    :phase,
    :ordinal,
    :kind,
    :chunk,
    :attempt,
    :transcript_root
  ]

  @kinds [:phase, :implement_chunk, :auto_remediation, :remediation, :describe]

  @type t :: %__MODULE__{
          repo_id: String.t() | nil,
          run_id: String.t(),
          feature_id: String.t(),
          phase: atom(),
          ordinal: pos_integer(),
          kind: :phase | :implement_chunk | :auto_remediation | :remediation | :describe | nil,
          chunk: term() | nil,
          attempt: pos_integer() | nil,
          transcript_root: Path.t()
        }

  @spec validate(term()) :: {:ok, t()} | {:error, {:bad_identity, atom()}}
  def validate(%__MODULE__{} = id) do
    cond do
      not non_empty?(id.run_id) -> bad(:run_id)
      not non_empty?(id.feature_id) -> bad(:feature_id)
      not (is_atom(id.phase) and not is_nil(id.phase)) -> bad(:phase)
      not (is_integer(id.ordinal) and id.ordinal > 0) -> bad(:ordinal)
      not non_empty?(id.transcript_root) -> bad(:transcript_root)
      id.kind != nil and id.kind not in @kinds -> bad(:kind)
      true -> {:ok, id}
    end
  end

  def validate(_), do: bad(:identity)

  @doc "Identity as a JSON-ready map, without the filesystem root."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = id) do
    %{
      "run_id" => id.run_id,
      "feature_id" => id.feature_id,
      "phase" => Atom.to_string(id.phase),
      "ordinal" => id.ordinal,
      "kind" => id.kind && Atom.to_string(id.kind),
      "chunk" => id.chunk && inspect(id.chunk),
      "attempt" => id.attempt
    }
  end

  defp non_empty?(s), do: is_binary(s) and s != ""
  defp bad(field), do: {:error, {:bad_identity, field}}
end
