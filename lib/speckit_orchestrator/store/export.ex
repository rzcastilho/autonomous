defmodule SpeckitOrchestrator.Store.Export do
  @moduledoc """
  Pure single-file JSON encoder (018, contracts/export-format.md). No
  `:mnesia` reference, no store path, no worktree path, no node name
  (FR-032b) — `encode/1` takes an already-assembled run export and returns
  iodata. Transcript bytes are embedded verbatim (FR-029a): valid UTF-8 is
  inlined as `"encoding": "utf8"`; anything else is base64-encoded as
  `"encoding": "base64"` — lossless either way, never a transformation of
  content.
  """

  alias SpeckitOrchestrator.Store.Records

  @format "speckit.run-export"
  @format_version 1

  @type phase_attempt_export :: %{
          attempt: Records.PhaseAttempt.t(),
          transcript: Records.Transcript.t() | nil
        }

  @type feature_export :: %{
          feature_id: binary(),
          slug: binary(),
          path: binary(),
          number: pos_integer(),
          group: :backlog | :ad_hoc,
          created_at: DateTime.t() | nil,
          status: atom(),
          terminal_reason: term(),
          branch: binary() | nil,
          worktree_path: binary() | nil,
          pr_description: map() | nil,
          checkpoint: Records.Checkpoint.t() | nil,
          escalations: [Records.Escalation.t()],
          remediation_attempts: [Records.RemediationAttempt.t()],
          phase_attempts: [phase_attempt_export()]
        }

  @type input :: %{
          exported_at: DateTime.t(),
          app_version: binary(),
          schema_version: pos_integer(),
          repo_id: binary(),
          origin: binary() | nil,
          run: map(),
          settings: map(),
          amendments: [Records.SettingsAmendment.t()],
          cost_entries: [Records.CostEntry.t()],
          features: [feature_export()]
        }

  @doc "The export document for `input`, as iodata (never a directory, never a side file — FR-032a)."
  @spec encode(input()) :: iodata()
  def encode(input) do
    input
    |> to_document()
    |> Jason.encode_to_iodata!()
  end

  defp to_document(input) do
    %{
      "format" => @format,
      "format_version" => @format_version,
      "exported_at" => iso8601(input.exported_at),
      "producer" => %{
        "app" => "speckit_orchestrator",
        "version" => input.app_version,
        "schema_version" => input.schema_version
      },
      "repository" => %{"repo_id" => input.repo_id, "origin" => input.origin},
      "run" => run_document(input)
    }
  end

  defp run_document(input) do
    run = input.run

    %{
      "run_id" => run.run_id,
      "state" => to_string(run.state),
      "outcome" => stringify(run.outcome),
      "started_at" => iso8601(run.started_at),
      "ended_at" => iso8601(run.ended_at),
      "duration_ms" => run.duration_ms,
      "spend_usd" => run.spend_usd,
      "record_complete" => run.record_complete?,
      "halt_reason" => safe_term(run.halt_reason),
      "stopped_by" => run.stopped_by,
      "stopped_reason" => safe_term(run.stopped_reason),
      "scope" => scope_document(run.scope),
      "superseded_by" => run.superseded_by,
      "settings" => safe_term(input.settings),
      "settings_amendments" => Enum.map(input.amendments, &amendment_document/1),
      "cost_entries" => Enum.map(input.cost_entries, &cost_entry_document/1),
      "features" => Enum.map(input.features, &feature_document/1)
    }
  end

  defp scope_document({:breakdown, slug}), do: %{"breakdown" => slug}
  defp scope_document(:ad_hoc), do: "ad_hoc"

  defp amendment_document(%Records.SettingsAmendment{} = a) do
    %{
      "ordinal" => a.ordinal,
      "changes" => safe_term(a.changes),
      "effective_at" => iso8601(a.effective_at),
      "effective_after" => a.effective_after && attempt_ref(a.effective_after)
    }
  end

  defp cost_entry_document(%Records.CostEntry{} = c) do
    %{
      "attempt" => attempt_ref(c.id),
      "amount_usd" => c.amount_usd,
      "kind" => to_string(c.kind),
      "recorded_at" => iso8601(c.recorded_at)
    }
  end

  defp feature_document(f) do
    %{
      "feature_id" => f.feature_id,
      "slug" => f.slug,
      "path" => f.path,
      "number" => f.number,
      "group" => to_string(f.group),
      "created_at" => iso8601(Map.get(f, :created_at)),
      "status" => to_string(f.status),
      "terminal_reason" => safe_term(f.terminal_reason),
      "branch" => f.branch,
      "worktree_path" => f.worktree_path,
      "pr_description" => safe_term(f.pr_description),
      "checkpoint" => checkpoint_document(Map.get(f, :checkpoint)),
      "escalations" => Enum.map(Map.get(f, :escalations, []), &escalation_document/1),
      "remediation_attempts" =>
        Enum.map(Map.get(f, :remediation_attempts, []), &remediation_document/1),
      "phase_attempts" => Enum.map(Map.get(f, :phase_attempts, []), &phase_attempt_document/1)
    }
  end

  defp checkpoint_document(nil), do: nil

  defp checkpoint_document(%Records.Checkpoint{} = c) do
    %{
      "phase" => to_string(c.phase),
      "last_completed_phase" => to_string(c.last_completed_phase),
      "status" => to_string(c.status),
      "reason" => safe_term(c.reason),
      "implement_chunk" => safe_term(c.implement_chunk),
      "analyze_remediation" => safe_term(c.analyze_remediation)
    }
  end

  defp escalation_document(%Records.Escalation{} = e) do
    %{
      "ordinal" => elem(e.id, 3),
      "kind" => to_string(e.kind),
      "phase" => to_string(e.phase),
      "severity" => stringify(e.severity),
      "reason" => safe_term(e.reason),
      "evidence" => safe_term(e.evidence),
      "raised_at" => iso8601(e.raised_at),
      "resolution" => safe_term(e.resolution)
    }
  end

  defp remediation_document(%Records.RemediationAttempt{} = r) do
    %{
      "ordinal" => r.ordinal,
      "findings" => safe_term(r.findings),
      "max_severity" => to_string(r.max_severity),
      "outcome" => to_string(r.outcome),
      "cost_usd" => r.cost_usd,
      "attempt_limit" => r.attempt_limit,
      "threshold" => to_string(r.threshold),
      "model" => r.model,
      "attempt" => r.attempt_id && attempt_ref(r.attempt_id)
    }
  end

  defp phase_attempt_document(%{attempt: a} = export) do
    %{
      "attempt" => attempt_ref(a.attempt_id),
      "phase" => to_string(a.phase),
      "ordinal" => a.ordinal,
      "step" => a.step,
      "label" => a.label,
      "started_at" => iso8601(a.started_at),
      "ended_at" => iso8601(a.ended_at),
      "duration_ms" => a.duration_ms,
      "outcome" => to_string(a.outcome),
      "model" => a.model,
      "cost_usd" => a.cost_usd,
      "cost_kind" => to_string(a.cost_kind),
      "substep" => safe_term(a.substep),
      "session_id" => a.session_id,
      "error" => safe_term(a.error),
      "transcript" => transcript_document(export[:transcript])
    }
  end

  defp transcript_document(nil), do: nil

  defp transcript_document(%Records.Transcript{} = t) do
    {encoding, content} =
      if String.valid?(t.body) do
        {"utf8", t.body}
      else
        {"base64", Base.encode64(t.body)}
      end

    %{
      "encoding" => encoding,
      "bytes" => t.bytes,
      "written_at" => iso8601(t.written_at),
      "content" => content
    }
  end

  # `{repo_id, run_id, feature_id, phase, ordinal}` -> `"<feature_id>:<phase>:<ordinal>"`
  # (contracts/export-format.md rule 4) — resolvable within the file with no
  # store reference.
  defp attempt_ref({_repo_id, _run_id, feature_id, phase, ordinal}),
    do: "#{feature_id}:#{phase}:#{ordinal}"

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify(nil), do: nil
  defp stringify(atom) when is_atom(atom), do: to_string(atom)

  # Lossless best-effort JSON-safety for arbitrary recorded terms (`reason`,
  # `evidence`, `halt_reason`, `error`, …): maps/lists/tuples recurse, atoms
  # (other than true/false/nil) stringify, everything else that Jason already
  # understands passes through, anything else falls back to `inspect/1` rather
  # than being dropped or defaulted.
  defp safe_term(nil), do: nil
  defp safe_term(term) when is_boolean(term), do: term

  defp safe_term(term) when is_map(term) and not is_struct(term),
    do: Map.new(term, fn {k, v} -> {to_string(k), safe_term(v)} end)

  defp safe_term(term) when is_list(term), do: Enum.map(term, &safe_term/1)
  defp safe_term(term) when is_tuple(term), do: term |> Tuple.to_list() |> safe_term()
  defp safe_term(term) when is_atom(term), do: to_string(term)
  defp safe_term(term) when is_binary(term) or is_number(term), do: term
  defp safe_term(term), do: inspect(term)
end
