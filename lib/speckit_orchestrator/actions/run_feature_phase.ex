defmodule SpeckitOrchestrator.Actions.RunFeaturePhase do
  @moduledoc """
  Run one pipeline phase for the agent's feature and fold the result back into
  agent state. Routed by the `"phase.run"` signal (`data: %{phase: atom}`).

  Reads `feature`, `worktree`, `session_id`, and `ledger` from the agent state
  (`context[:agent].state`), builds the request with
  `PhaseRequest.build/3`, runs it through the harness, folds a `PhaseResult`,
  extracts the phase's **gate signals**, resolves and records cost, and writes
  `last_outcome` / `last_signals` / `session_id` / `history` / `cost_total` back
  to state. It does **not** decide the transition — the `FeatureRunner` owns
  `Pipeline.next/3`.

  Every gate that reads a file resolves **this feature's** spec directory
  through `SpecDir` first. A stacked worktree carries every earlier feature's
  `specs/` directory, so a `specs/**/…` glob answers a question about some other
  feature — see `SpecDir`'s docs for what that cost.

  Gate extraction:
  * `:clarify` → `needs_human?` when the transcript carries the literal
    `## NEEDS HUMAN` marker.
  * `:analyze` → `critical?` / `high?` from `AnalyzeResult.parse/1`; **malformed
    analyze JSON is an error outcome**, never a silent pass.
  * `:plan` / `:tasks` / `:implement` → `missing_artifact` when the phase
    returned a successful transcript but produced none of the files it exists to
    write. A phase can refuse, ask an unanswerable question, or no-op on a
    missing upstream artifact and still look perfectly successful — only the
    filesystem tells the truth.
  * `:converge` → `not_ready?` from the `## CONVERGE: NOT READY` marker.
  """

  use Jido.Action,
    name: "run_feature_phase",
    description: "Run one Spec Kit phase and record the result into agent state",
    schema: [
      phase: [type: :atom, required: true],
      scope: [type: :any, required: false, default: nil],
      first_chunk: [type: :boolean, required: false, default: false]
    ]

  require Logger

  alias SpeckitOrchestrator.{
    AnalyzeResult,
    ArtifactSubstance,
    Cost,
    Ledger,
    PhaseRequest,
    PhaseResult,
    SpecDir
  }

  # The escalation signal is the literal `## NEEDS HUMAN` heading emitted by the
  # clarify reviewer. Match it only as a real Markdown heading (line start, whole
  # line) — a naive substring match trips on prose that *mentions* the marker,
  # e.g. "No `## NEEDS HUMAN` — nothing material left", turning a clean pass into
  # a false escalation.
  @needs_human_marker ~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m

  # Converge's verdict line (see priv/prompts/converge.md). Line-anchored for the
  # same reason as the NEEDS HUMAN marker: prose that *mentions* the marker must
  # not trip the gate. Absence of any marker is treated as ready — the artifact
  # gate is the primary net for an unbuilt feature, so a model that forgets the
  # line does not fail an otherwise good run.
  @converge_not_ready_marker ~r/^\#\#[ \t]+CONVERGE:[ \t]+NOT READY[ \t]*$/m

  @impl true
  def run(%{phase: phase} = params, context) do
    state = context[:agent].state
    scope = Map.get(params, :scope)

    # Each Spec Kit phase is a fresh `claude -p` session — phase state persists in
    # repo files, not the session. We capture the session id into agent state for
    # observability/cancellation, but never resume it into the next phase's
    # request (that would hit the adapter's resume path). Mid-pipeline session
    # resume is a v2 concern.
    request =
      PhaseRequest.build(state.feature, phase,
        cwd: worktree_path(state.worktree),
        resume_prompt: resume_prompt_for(state, phase, params),
        layout: state.layout,
        scope: scope
      )

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} ->
        result = PhaseResult.reduce(stream)
        {outcome, signals} = classify(phase, result, state, scope)
        {amount, _source} = Cost.for_phase(phase, result)
        record_cost(state.ledger, amount)

        {:ok,
         %{
           phase: phase,
           last_result: result,
           last_outcome: outcome,
           last_signals: signals,
           session_id: result.session_id || state.session_id,
           cost_total: (state.cost_total || 0.0) + amount,
           history: [entry(phase, outcome, amount) | state.history]
         }}

      {:error, reason} ->
        {:ok,
         %{
           phase: phase,
           last_outcome: :error,
           last_signals: %{},
           last_result: nil,
           history: [%{phase: phase, outcome: :error, error: reason} | state.history]
         }}
    end
  end

  # Operator guidance is scoped to exactly the phase the run was resumed at —
  # the fixed `resume_phase` anchor, not the currently-advancing `phase` — and,
  # unchanged, reinjects on every retry of that phase (run_feature_phase_test.exs
  # "resume_prompt re-injects on every retry"). A *chunked* implement step
  # dispatches many `"phase.run"` signals that all carry `phase: :implement`,
  # so that same match would otherwise repeat the note into every task-phase's
  # session — `ChunkRunner` marks exactly one dispatch `first_chunk: true`
  # (contracts/checkpoint-implement-chunk.md §4, FR-024) and every other
  # scoped (`scope != nil`) call gets none, matching "guidance reaches the
  # first dispatched task-phase session, matching existing whole-step resume
  # behaviour" without touching the non-chunked path's retry semantics at all.
  defp resume_prompt_for(state, phase, params) do
    cond do
      phase != state.resume_phase -> nil
      is_nil(Map.get(params, :scope)) -> state.resume_prompt
      Map.get(params, :first_chunk, false) -> state.resume_prompt
      true -> nil
    end
  end

  # ---- gate classification ------------------------------------------------

  # Incomplete-session gate, ahead of every phase-specific clause.
  #
  # A headless session that ends its turn ends the session — there is no next
  # turn in which a background subagent's result could arrive, and nothing
  # collects it afterwards. So a `:session_completed` carrying unreturned tool
  # calls is a session that stopped mid-flight while reporting success, and
  # `PhaseResult.outstanding_work?/1` is the mechanical signature of it.
  #
  # Suppressed when the phase's own artifact gate is satisfied: the contract of
  # an artifact-producing phase is the file, and a filled-in file is positive
  # evidence the contract was met no matter what the model left dangling. That
  # keeps the detector from second-guessing a phase that demonstrably worked,
  # and leaves it as the generic net for the phases that have no artifact gate
  # at all (`:specify`, `:clarify`, `:analyze`, `:converge`, `:describe`).
  defp classify(phase, %PhaseResult{status: :ok} = r, state, scope) do
    if PhaseResult.outstanding_work?(r) and not gate_satisfied?(phase, state, scope) do
      Logger.warning(
        "phase #{phase} reported success with unreturned tool calls " <>
          "(#{Enum.join(PhaseResult.outstanding_calls(r), ", ")}) — treating as incomplete"
      )

      {:error, %{outstanding_work?: true}}
    else
      classify_gate(phase, r, state, scope)
    end
  end

  defp classify(phase, %PhaseResult{} = r, state, scope),
    do: classify_gate(phase, r, state, scope)

  # True when `phase` has an artifact gate and it passes. A scoped implement
  # chunk counts as satisfied — its gate is deferred to `ChunkRunner`'s roll-up
  # and this detector must never pre-empt that.
  defp gate_satisfied?(:implement, _state, scope) when not is_nil(scope), do: true

  defp gate_satisfied?(phase, state, _scope) when phase in [:plan, :tasks, :implement],
    do: is_nil(missing_artifact(state.worktree, phase, feature: state.feature))

  defp gate_satisfied?(_phase, _state, _scope), do: false

  # Escalate if the marker is in the clarify RESPONSE **or** left unresolved in
  # the spec file. The reviewer can write `## NEEDS HUMAN` into `spec.md` while
  # its response summary reads clean — checking only the response lets a real,
  # material escalation slip past the gate, and the next phase (`plan`) then
  # refuses on the unresolved clarification but reports `:ok` (a false-green).
  defp classify_gate(:clarify, %PhaseResult{} = r, state, _scope) do
    needs_human? =
      Regex.match?(@needs_human_marker, r.final_text || "") or
        spec_has_needs_human?(state.worktree, state.feature)

    {outcome_of(r), %{needs_human?: needs_human?}}
  end

  defp classify_gate(:analyze, %PhaseResult{status: :ok} = r, _state, _scope) do
    case AnalyzeResult.parse(r.final_text) do
      {:ok, parsed} -> {:ok, %{critical?: parsed.critical?, high?: parsed.high?}}
      # malformed / absent analyze JSON = failure, not a silent pass
      {:error, _reason} -> {:error, %{critical?: false}}
    end
  end

  # A chunked (scoped) implement session defers the artifact gate to
  # `ChunkRunner`, which evaluates it once on the roll-up (research R10) — a
  # single task-phase's scoped session legitimately writes nothing (e.g. a
  # doc-only phase) without that meaning the feature produced no
  # implementation at all.
  defp classify_gate(:implement, %PhaseResult{status: :ok}, _state, scope)
       when not is_nil(scope) do
    {:ok, %{}}
  end

  # Artifact gate: a successful transcript proves nothing — check the tree.
  defp classify_gate(phase, %PhaseResult{status: :ok}, state, _scope)
       when phase in [:plan, :tasks, :implement] do
    case missing_artifact(state.worktree, phase, feature: state.feature) do
      nil ->
        {:ok, %{}}

      artifact ->
        # `unfilled_artifact?` splits the two ways this gate fails, because they
        # deserve different retry treatment (see `PhaseStep`): a file that was
        # never written usually means a deterministic refusal, while a file left
        # as scaffolding is positive evidence the model started and stopped.
        # Added only in the unfilled case, so the signal map for a plainly
        # missing artifact stays byte-identical to what it has always been.
        signals = %{missing_artifact: artifact}

        {:ok,
         if(unfilled?(artifact), do: Map.put(signals, :unfilled_artifact?, true), else: signals)}
    end
  end

  defp classify_gate(:converge, %PhaseResult{status: :ok} = r, _state, _scope) do
    {:ok, %{not_ready?: Regex.match?(@converge_not_ready_marker, r.final_text || "")}}
  end

  defp classify_gate(_phase, %PhaseResult{} = r, _state, _scope), do: {outcome_of(r), %{}}

  # ---- artifact gate ------------------------------------------------------

  # Resolved through `SpecDir`, not globbed. `specs/**/plan.md` asks "does a
  # plan.md exist anywhere in this tree", and in a stacked worktree — which
  # carries every earlier feature's `specs/` directory — the answer is yes before
  # this feature's plan phase has written a thing. The gate exists to prove
  # *this* feature produced the file, so a prior feature's copy satisfying it is
  # a false green: plan reports :ok, and the failure only surfaces later as
  # something less obvious. `SpecDir` still tolerates a differently-named spec
  # dir, which is what the glob was really buying.
  @phase_artifacts %{plan: "plan.md", tasks: "tasks.md"}

  # Suffix appended to the artifact name when the file exists but is untouched
  # scaffolding. Matched, not reconstructed, so the two producers stay in sync.
  @unfilled " (unfilled template)"

  # Paths that exist even when nothing was implemented — spec/plan/task docs, the
  # single-spec seed, and the orchestrator's own logs.
  @non_implementation_prefixes ~w(specs/ docs/breakdown/ .speckit_logs/ .speckit-transcripts/ .specify/)

  @doc """
  Whether an `:implement` worktree carries no implementation changes
  (research R10) — `"implementation changes"` when there's nothing to show,
  else `nil`. Exposed for `ChunkRunner`, which runs this same check once on
  the roll-up when the per-chunk gate was deferred (`classify/4` above, scope
  present).

  `:since` (a git ref) additionally counts changes already **committed** after
  that point — `ChunkRunner` commits at every task-phase boundary (FR-023a),
  so by roll-up time a chunked run's changes are no longer sitting dirty in
  the tree; without `:since` the plain dirty-tree check below would see
  nothing and wrongly report a successful implementation as missing one.

  The ref must be the branch's **fork point from its stack base**
  (`Worktree.fork_point/2`), not the worktree's HEAD when the invocation
  started. HEAD only agrees with the fork point on a feature's *first*
  implement invocation; on a resume, every earlier task phase's commit is
  already below it, and the gate then judges the feature on the resumed slice
  alone — failing a fully-implemented feature whose resumed slice happened to
  write no code. Non-chunked callers omit it and get dirty-tree-only behavior.
  """
  @spec missing_implement_artifact(SpeckitOrchestrator.Worktree.t() | nil, keyword()) ::
          String.t() | nil
  def missing_implement_artifact(worktree, opts \\ []),
    do: missing_artifact(worktree, :implement, opts)

  # No worktree (dry runs / unit tests) → nothing to check.
  defp missing_artifact(%{path: path}, phase, opts) when is_binary(path) do
    case phase do
      :implement ->
        if implementation_changes?(path, Keyword.get(opts, :since)),
          do: nil,
          else: "implementation changes"

      _ ->
        scoped_artifact(path, @phase_artifacts[phase], Keyword.get(opts, :feature), phase)
    end
  end

  defp missing_artifact(_worktree, _phase, _opts), do: nil

  # An unresolvable spec dir reports the artifact missing — the opposite
  # direction from the clarify scan, and deliberately so: this gate exists to
  # fail loud when a phase produced nothing, and "I could not find where this
  # feature's files live" is not evidence that it produced them.
  #
  # Existence is necessary but not sufficient. `setup-plan.sh` copies
  # `plan-template.md` into place *before* the model writes anything, so a plan
  # session that ends early leaves a file that satisfies a pure existence check
  # while containing no plan at all — `ArtifactSubstance` is what tells the two
  # apart. The reason string stays short and stable because the console and the
  # run report render it verbatim; the matched families go to the log.
  defp unfilled?(artifact) when is_binary(artifact), do: String.ends_with?(artifact, @unfilled)
  defp unfilled?(_artifact), do: false

  defp scoped_artifact(worktree_path, leaf, feature, phase) do
    case SpecDir.file(worktree_path, feature, leaf) do
      nil ->
        leaf

      found ->
        case ArtifactSubstance.verdict(found, phase, worktree: worktree_path) do
          :filled ->
            nil

          {:unfilled, families} ->
            Logger.warning(
              "#{phase} left #{leaf} as unfilled scaffolding " <>
                "(#{Enum.map_join(families, ", ", &to_string/1)})"
            )

            leaf <> @unfilled
        end
    end
  end

  # True when the worktree carries at least one change outside the spec/doc
  # scaffolding — i.e. implement actually wrote code. A git failure returns true
  # (can't tell → don't fail the feature on a broken probe). `since` (a git
  # ref) additionally counts changes already committed after that point — see
  # `missing_implement_artifact/2`.
  defp implementation_changes?(worktree_path, since) do
    case changed_paths(worktree_path, since) do
      {:ok, paths} -> Enum.any?(paths, &implementation_path?/1)
      :error -> true
    end
  end

  defp changed_paths(worktree_path, nil) do
    case System.cmd("git", ["-C", worktree_path, "status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.map(&changed_path/1)}
      _ -> :error
    end
  end

  defp changed_paths(worktree_path, since) do
    with {:ok, dirty} <- changed_paths(worktree_path, nil),
         {committed, 0} <-
           System.cmd("git", ["-C", worktree_path, "diff", "--name-only", since, "HEAD"],
             stderr_to_stdout: true
           ) do
      {:ok, dirty ++ String.split(committed, "\n", trim: true)}
    else
      _ -> :error
    end
  end

  # Porcelain v1 line: 2 status chars + space + path (renames use "old -> new").
  defp changed_path(line) do
    line |> String.slice(3..-1//1) |> String.split(" -> ") |> List.last() |> String.trim("\"")
  end

  defp implementation_path?(""), do: false

  defp implementation_path?(path),
    do: not Enum.any?(@non_implementation_prefixes, &String.starts_with?(path, &1))

  # True when **this feature's** `spec.md` still carries an unresolved
  # `## NEEDS HUMAN` heading (line-anchored, same as the response check).
  #
  # Scoped, not globbed: a stacked worktree carries every earlier feature's
  # `specs/` directory, so scanning `specs/**/spec.md` escalated a clean feature
  # because some *previous* feature's spec still held a marker — and once one
  # feature legitimately escalates, its marker stays in the tree and every
  # descendant inherits the escalation.
  #
  # An unresolvable spec dir reads as "no marker": this file scan is the
  # secondary net behind the clarify response check, and escalating on a file we
  # cannot even identify as this feature's would block good runs. No worktree
  # (dry runs / tests) → false, unchanged.
  defp spec_has_needs_human?(%{path: path}, feature) when is_binary(path) do
    case SpecDir.file(path, feature, "spec.md") do
      nil ->
        false

      file ->
        case File.read(file) do
          {:ok, content} -> Regex.match?(@needs_human_marker, content)
          _ -> false
        end
    end
  end

  defp spec_has_needs_human?(_worktree, _feature), do: false

  # A run that did not reach a successful terminal event is an error outcome
  # (covers :error and :incomplete).
  defp outcome_of(%PhaseResult{status: :ok}), do: :ok
  defp outcome_of(%PhaseResult{}), do: :error

  # ---- helpers ------------------------------------------------------------

  defp entry(phase, outcome, amount), do: %{phase: phase, outcome: outcome, cost: amount}

  defp worktree_path(%{path: path}), do: path
  defp worktree_path(_), do: SpeckitOrchestrator.Config.repo()

  defp record_cost(nil, _amount), do: :ok
  defp record_cost(ledger, amount), do: Ledger.record(ledger, nil, amount)
end
