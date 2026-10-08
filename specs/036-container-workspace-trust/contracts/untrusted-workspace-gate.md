# Contract: Untrusted-Workspace Gate (FR-013, US1 scenarios 4–5)

Applies to every run, container or host, at every session-driving site.

## 1. Detection — `Autonomous.WorkspaceTrust` (pure)

The only module that knows the CLI's wording (Principle I: one boundary per
external contract).

```elixir
@spec parse_line(String.t()) :: {:untrusted, %{workspace: String.t() | nil, kind: String.t() | nil}} | :other
@spec observe([String.t()]) :: nil | %{workspace: String.t() | nil, kinds: [String.t()]}
```

Matching (CLI 2.1.286/2.1.294, research R2):

| stderr line | Result |
|---|---|
| `Ignoring 6 permissions.allow entries from .claude/settings.json: this workspace has not been trusted. … set projects["/x/repo"].hasTrustDialogAccepted: true in /home/u/.claude.json.` | `{:untrusted, %{workspace: "/x/repo", kind: "permissions.allow"}}` |
| `Ignoring 1 permissions.additionalDirectories entry from …: this workspace has not been trusted. …` | `kind: "permissions.additionalDirectories"` |
| `Ignoring 2 permissions.allow entries from .claude/settings.json: a session with no working directory is never trusted.` | `workspace: nil` |
| line contains `has not been trusted` but no parsable `projects[...]` | `{:untrusted, %{workspace: nil, kind: nil}}` — still untrusted (fail toward reporting) |
| anything else | `:other` |

`observe/1` folds lines → `nil` when none untrusted; else first non-nil
workspace and the deduped kinds in order seen.

Fixtures: real captured lines (from the research probe and the smoke check),
checked into `test/fixtures/cli_stderr/`.

## 2. Capture — per session

- `PhaseRequest` builds `metadata["claude"][:stderr]` = a 1-arity callback.
  The callback (a) logs exactly as the SDK default did
  (`Logger.warning("CLI stderr: " <> line)`) and (b) forwards the line to the
  session's collector when `parse_line/1` ≠ `:other`.
- Collector: one lightweight process per session under `Autonomous.SessionSup`,
  started by the session-driving site before `Jido.Harness.run_request/3`,
  read and stopped after `PhaseSession.reduce/2` returns (any outcome,
  including deadline and session death). A send to a stopped collector is
  dropped.
- Result: `PhaseResult` gains `untrusted_workspace: observation | nil`.

## 3. Decision — at the session-driving site

```text
observation = WorkspaceTrust.observe(collected_lines)
case {observation, run_profile} do
  {nil, _}              -> no signal
  {obs, "strict"}       -> signals.untrusted_workspace = obs
  {obs, "permissive"}   -> Logger.warning("untrusted workspace #{obs.workspace || "(no working directory)"}: CLI ignored #{Enum.join(obs.kinds, ", ")} from the committed pack; continuing under permissive")
end
```

Sites (all, identically): `RunFeaturePhase`, `RunAutoRemediation`,
`RunRemediation`, `ChunkRunner`/`Chunking` (implement chunks),
`AnalyzeRunner` (analyze + remediation sessions).

## 4. Gate — `Pipeline.next/3` (pure)

Evaluation order for a phase outcome:

1. `branch_drift` → `{:branch_drift, phase, d}`
2. `session_died` → `{:session_died, phase, d}`
3. **`untrusted_workspace` → `{:untrusted_workspace, phase, obs}`** (NEW; applies whether the session status is `:ok` or `:error`)
4. `backgrounded` → `{:backgrounded_command, phase, cmds}`
5. `outstanding_work?` → `{:incomplete_session, phase}`
6. generic → `{phase, :error}`

Terminal status: `:failed`. With no signal, `next/3` is byte-identical to
before 036.

## 5. Retry

- `PhaseStep.retry_reason/1` → `nil` for `untrusted_workspace` (short-circuit,
  same as branch drift).
- `SessionRetry.once/2`, `Chunking` died-retry: not triggered.
- Not a breaker/drain event; spend already incurred is accounted as today.

## 6. Commit / worktree

Same as other non-drift `:failed` terminals: work is committed on the feature
branch and the worktree kept for inspection. Resume after the operator trusts
the target: `Autonomous.resume/2` from the failed phase.

## Invariants

- **U1.** Under `strict`, a session that printed an untrusted line never yields
  a successful phase (SC-007).
- **U2.** Under `permissive`, the gate never changes the outcome; it only logs.
- **U3.** No untrusted line ⇒ every outcome identical to pre-036.
