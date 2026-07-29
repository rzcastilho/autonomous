defmodule SpeckitOrchestrator.Store.Ids do
  @moduledoc """
  Pure `run_id`/key/`attempt_id` derivation (018, data-model.md "Identity and
  partitioning"). No schema, no running node, no `:mnesia` reference
  (Principle I).

  `repo_id` itself is derived by `SpeckitOrchestrator.RepoIdentity.partition/1`,
  not here — this module only shapes the identifiers that nest under a
  `repo_id` once one exists.
  """

  @type repo_id :: binary()
  @type run_id :: binary()
  @type feature_id :: binary()
  @type run_key :: {repo_id(), run_id()}
  @type feature_key :: {repo_id(), run_id(), feature_id()}
  @type attempt_id :: {repo_id(), run_id(), feature_id(), atom(), pos_integer()}
  @type ordinal_id :: {repo_id(), run_id(), feature_id(), pos_integer()}
  @type amendment_id :: {repo_id(), run_id(), pos_integer()}

  @run_id_digits 6

  @doc """
  `"r" <> zero-padded 6-digit per-repository sequence` (e.g. `"r000004"`).
  Ordered-set key order on `speckit_run` is chronological order because this
  zero-pads (FR-033) — no clock dependency. Documented ceiling: 999_999.
  """
  @spec run_id(pos_integer()) :: run_id()
  def run_id(seq) when is_integer(seq) and seq > 0 do
    "r" <> String.pad_leading(Integer.to_string(seq), @run_id_digits, "0")
  end

  @doc "The integer sequence a `run_id/1` was derived from."
  @spec run_seq(run_id()) :: pos_integer()
  def run_seq("r" <> digits), do: String.to_integer(digits)

  @doc "`{repo_id, run_id}` — the primary key of `speckit_run` and every child row's parent reference."
  @spec run_key(repo_id(), run_id()) :: run_key()
  def run_key(repo_id, run_id) when is_binary(repo_id) and is_binary(run_id),
    do: {repo_id, run_id}

  @doc "`{repo_id, run_id, feature_id}` — the primary key of `speckit_feature_run`."
  @spec feature_key(repo_id(), run_id(), feature_id()) :: feature_key()
  def feature_key(repo_id, run_id, feature_id)
      when is_binary(repo_id) and is_binary(run_id) and is_binary(feature_id),
      do: {repo_id, run_id, feature_id}

  @doc """
  `{repo_id, run_id, feature_id, phase, ordinal}` — the primary key of
  `speckit_phase_attempt` and, unchanged, of `speckit_transcript`, so a
  transcript cannot be separated from the attempt it describes (FR-035).
  """
  @spec attempt_id(repo_id(), run_id(), feature_id(), atom(), pos_integer()) :: attempt_id()
  def attempt_id(repo_id, run_id, feature_id, phase, ordinal)
      when is_binary(repo_id) and is_binary(run_id) and is_binary(feature_id) and
             is_atom(phase) and is_integer(ordinal) and ordinal > 0,
      do: {repo_id, run_id, feature_id, phase, ordinal}

  @doc "`{repo_id, run_id, feature_id, ordinal}` — the primary key shape shared by escalations and remediation attempts."
  @spec ordinal_id(repo_id(), run_id(), feature_id(), pos_integer()) :: ordinal_id()
  def ordinal_id(repo_id, run_id, feature_id, ordinal)
      when is_binary(repo_id) and is_binary(run_id) and is_binary(feature_id) and
             is_integer(ordinal) and ordinal > 0,
      do: {repo_id, run_id, feature_id, ordinal}

  @doc "`{repo_id, run_id, ordinal}` — the primary key of `speckit_settings_amendment`."
  @spec amendment_id(repo_id(), run_id(), pos_integer()) :: amendment_id()
  def amendment_id(repo_id, run_id, ordinal)
      when is_binary(repo_id) and is_binary(run_id) and is_integer(ordinal) and ordinal > 0,
      do: {repo_id, run_id, ordinal}
end
