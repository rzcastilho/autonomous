# Operator runbook

How to run the orchestrator, watch a run, unblock it, and verify what it
produced. The operator surface is `iex` plus
`SpeckitOrchestrator.{run, status, print_status, resolve}`.

Everything here was validated against the LedgerLite Phase 7 target — see
`docs/phase7-ledgerlite-runbook.md` for the validation protocol and traps.

---

## Prerequisites

1. **Toolchain.** Elixir 1.20.2 / OTP 28 — run every command through mise
   (`mise exec -- mix …`); the bare PATH is a stale global Elixir.
2. **Claude Code CLI**, installed and authenticated. A stored interactive login
   (`claude` logged in) is sufficient — no env key is required if the CLI is
   logged in. Alternatively set one of `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`.
   Verify: `claude --version`.
3. **Model-pin env vars (required for reproducibility).** Per-phase routing uses
   CLI **aliases** (`opus`/`sonnet`); the pinned catalog rejects full model
   strings. Pin the alias → full-model mapping in the run environment, or every
   run silently floats to the CLI's current defaults:
   ```bash
   export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
   export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
   ```
4. **`specify` CLI** at the pinned tag (implementation-plan §2).

---

## First run — detailed step by step

### 1. Bootstrap the target repo (once)

The orchestrator drives a **separate** target repo. Bootstrap it with the Spec
Kit scaffold + the enforcement pack, then a real constitution.

```bash
# Fresh target repo (a sibling dir, not inside the orchestrator repo)
cd /path/to/parent
specify init my-target --integration claude --script sh --ignore-agent-tools
cd my-target && git init -q

# From the ORCHESTRATOR repo, lay in the enforcement pack:
mise exec -- mix run --no-start -e \
  'SpeckitOrchestrator.TargetPack.install("/path/to/my-target")'
```

`specify init` provides `.specify/` (templates + `.specify/scripts/*.sh`) and the
Spec Kit skills under `.claude/skills/`. `TargetPack.install` adds
`.claude/settings.json` (least-privilege — but it **must allow `Bash`**, because
the Spec Kit phase scripts run under Bash) and the `scope_guard.py` PreToolUse
hook.

### 2. Write a real constitution

Replace `.specify/memory/constitution.md` — remove the
`SPECKIT_ORCHESTRATOR_TEMPLATE` marker and write **checkable MUSTs** the analyze
gate can enforce (e.g. "monetary amounts stored/computed as integer cents;
floating-point money forbidden"). Vague principles cannot gate anything.

### 3. Add the feature breakdown

Put `docs/breakdown/NNN-slug.md` files in the target under its `:breakdown_dir`.
Each needs a `## Prerequisites` section (drives the DAG). **A breakdown that
delegates a decision the sources can't answer will stall `plan`/`clarify` — see
"Decide the tech stack" below.**

### 4. Commit the target and preflight

```bash
cd /path/to/my-target && git add -A && git commit -m "spec kit + enforcement pack"
```
```elixir
# preflight must be :ok before a run
SpeckitOrchestrator.TargetPack.verify("/path/to/my-target")   # => :ok
```
`verify` fails while the template constitution marker is present, or if the
constitution is uncommitted.

### 5. Point the orchestrator at the target + decide the tech stack

In `config/runtime.exs` (or via the `SPECKIT_REPO` env var, which wins):
```elixir
config :speckit_orchestrator, repo: "/path/to/my-target"
```

**Decide the tech stack (critical).** If the spec delegates language/format to
`plan` (most do), `plan` cannot proceed without one — with `plan_stack: []` it
stalls and the run false-greens (see Troubleshooting). Set it:
```elixir
config :speckit_orchestrator,
  plan_stack: ["Python 3 (standard library only: argparse, unittest; no deps)"]
```

### 6. Start the run

```elixir
iex -S mix
iex> SpeckitOrchestrator.Telemetry.attach_default_logger()   # log phase transitions
iex> {:ok, _coord} = SpeckitOrchestrator.run()
```

`run/0` loads the backlog, validates the DAG (raises on cycles / dangling
prereqs), and releases the first wave. Features run in dependency-and-cap waves
(`config :max_concurrency`). The caller receives `{:run_complete, report}` when
the run drains.

---

## Single-spec run (no backlog required)

To drive **exactly one** feature from a free-text description — no
`docs/breakdown/NNN-slug.md` file to author, no prerequisites to declare — use
`SpeckitOrchestrator.run_spec/2` instead of `run/1`:

```elixir
iex -S mix
iex> {:ok, _coord} = SpeckitOrchestrator.run_spec("""
...> Add a health-check endpoint that returns service status and version.
...> """)
iex> SpeckitOrchestrator.print_status()
```

`run_spec/2` auto-assigns the feature id (one past the highest existing
breakdown id or `feature/NNN-*` branch) and derives a kebab-case slug from the
description, materializes it as a one-off breakdown seed inside the feature's
own worktree so the existing `specify` phase reads it unchanged, and runs the
feature as a wave of one through the same `Coordinator` a backlog run uses — so
every guarantee (clarify escalation, analyze halt, cost-breaker drain-not-kill,
least-privilege containment, durable transcripts, worktree retention on a
non-`:done` outcome) applies identically. An empty or whitespace-only
description is rejected immediately with `{:error, :empty_description}` and
starts nothing.

The optional stacked PR workflow works too — `run_spec(description,
pr_workflow: true)` preflights the remote/pack, then pushes the branch and
opens a PR on `:done`, exactly like `run/1`.

See `specs/001-single-spec-run/quickstart.md` for the full validation walkthrough
(including the guarantee checks) and `specs/001-single-spec-run/contracts/run_spec.md`
for the interface contract.

---

## Stacked sequential PR workflow (opt-in)

An alternative to the default parallel-wave run that builds features **one at a
time** and opens a **pull request per feature**. Enable it with
`config :speckit_orchestrator, pr_workflow: true` (or per-run
`SpeckitOrchestrator.run(pr_workflow: true)`). When on, it enforces three things:

1. **Sequential** — concurrency is forced to 1; features build strictly in
   dependency/id order, one at a time.
2. **Remote required** — `run/1` preflights that the target repo has the
   configured remote (`:pr_remote`, default `origin`) and refuses to start with
   `{:error, {:preflight, problems}}` if it is missing (or the pack/constitution
   preflight otherwise fails).
3. **PR per feature** — when a feature reaches `:done`, its branch is pushed and a
   PR is opened. PRs are **stacked**: feature N branches from feature N-1's branch
   and its PR targets that branch (`001 → main`, `002 → feature/001`,
   `003 → feature/002`). Each PR carries a clean diff on top of its prerequisite;
   **you merge them bottom-up**.

Config knobs (`config :speckit_orchestrator`):

- `pr_workflow: false` — the master switch.
- `pr_base: "main"` — base branch for the first feature's PR.
- `pr_remote: "origin"` — remote to push to and preflight.

Extra prerequisites for this mode:

- The target repo has a remote (`git -C <repo> remote add origin <url>`); its base
  branch (`pr_base`) is pushed. Preflight: `TargetPack.verify(repo,
  check_remote: true)` must return `:ok`.
- The **`gh` CLI** is installed and authenticated on the run host (PRs are opened
  with `gh pr create`; it infers the repository from `origin`).

Notes:

- Push/PR are **best-effort** — a failure is logged and never fails the run; the
  local branch still exists, so the next feature stacks on it regardless. Reopen a
  missed PR by hand if needed.
- A PR is opened **only on `:done`**. Escalated/halted/failed features keep their
  worktree/branch for you to resolve (see "Respond to an escalation"); the PR
  opens after you resolve and the feature reaches `:done` on a re-run.
- Only the facade path changes; the DAG, breaker, gates, and transcripts behave
  exactly as documented elsewhere.

---

## Watch a run

```elixir
iex> SpeckitOrchestrator.print_status()
FEATURE  STATUS    ELAPSED
001      done      12.4s
002      running   3.1s
003      pending   -

totals: done=1  running=1  pending=1
spend:  $4.20
state:  running
```

- Phase transitions are logged (attach the default logger); telemetry is emitted
  under `[:speckit, :phase, …]` and `[:speckit, :feature, :terminal]`.
- **Transcripts (two locations):**
  - Live, in-worktree: `<worktree>/.speckit_logs/NN-<phase>.md`.
  - **Durable**: `<transcript_root>/<feature_id>/NN-<phase>.md`
    (`config :transcript_root`, default `<repo>/.speckit-transcripts` — **inside
    the target repo** so different targets never share a transcript dir; gitignore
    `.speckit-transcripts/`). These survive worktree teardown on `:done`, so a
    completed run's plan/tasks/implement transcripts stay inspectable. Read these
    to diagnose any phase.
- Rough cost: a full 7-phase feature build runs **~$10–12** (`clarify` and
  `implement` dominate). `config :budget_usd` (default 74.0) is the breaker cap.

---

## Verify a completed feature (do not trust `:done` alone)

`:done` means every phase returned a success *result event* — **not** that each
phase did its job. A phase that hits a blocker it can't escalate (e.g. `plan`
with no stack, or a denied Bash script) can return `:ok` while producing no
files: a **false-green**. Always verify the output:

```bash
T=/path/to/my-target
# 1. The pipeline commits generated artifacts to the branch on every terminal
#    (Worktree.commit), and Spec Kit's implement self-commits too. Inspect it:
git -C $T log --oneline feature/NNN-slug
git -C $T ls-tree -r --name-only feature/NNN-slug | grep -vE '\.specify/|\.claude/'

# 2. Confirm the planning + code artifacts actually exist:
#    specs/NNN-slug/{plan.md,tasks.md,data-model.md,contracts/}  AND source code.
#    If only spec.md + checklists exist -> plan/tasks/implement no-opped.

# 3. Run the generated tests (src-layout example — adjust per stack):
git -C $T worktree add /tmp/verify feature/NNN-slug
cd /tmp/verify && PYTHONPATH=src python3 -m unittest discover -s tests
git -C $T worktree remove --force /tmp/verify
```

If plan/tasks/implement produced nothing, read
`<transcript_root>/<feature_id>/03-plan.md` (etc.) for the blocker — usually a
missing tech stack or a Bash approval denial.

---

## Respond to an escalation

A feature that emits the `## NEEDS HUMAN` heading at `clarify` ends `:escalated`;
its worktree is **kept**. The report lists it under `escalated` and its
dependents under `blocked`.

**Escalations can span multiple rounds** — answering one round's questions can
expose the next round's second-order questions (e.g. deciding a date sort key
opens "does `add` take a date input?"). This is the gate converging, not a
failure.

1. **Read the escalation.** `<transcript_root>/<feature_id>/02-clarify.md` (or the
   kept worktree's `.speckit_logs/02-clarify.md`) and the spec's `## NEEDS HUMAN`
   section. Each item lists a precise question and the options considered.
2. **Answer in the BREAKDOWN, not just the spec.** A re-run's `specify`
   regenerates `spec.md` from the breakdown, so spec-only edits are discarded.
   Put the decisions in `docs/breakdown/NNN-slug.md` under a `## Decisions`
   section (the parser ignores everything but `## Prerequisites`, so this is
   safe). Make each decision specific and testable.
3. **Commit on the feature branch** (`feature/NNN-slug`) — the kept worktree is
   already on it:
   ```bash
   git -C <kept-worktree> add docs/breakdown/NNN-slug.md && git commit -m "resolve H-… for NNN"
   ```
4. **Free the worktree** (the branch commit is preserved):
   ```elixir
   iex> SpeckitOrchestrator.resolve("NNN")
   ```
5. **Re-run** `SpeckitOrchestrator.run()`. The feature reuses its branch and
   re-runs from the start (mid-pipeline resume is v2). With the decisions now in
   the breakdown, `clarify` should default/resolve and its dependents unblock.
   If a **new** round of questions appears, repeat 1–5.

---

## Cost breaker

If spend reaches `config :budget_usd`, the breaker trips: no new features are
released and in-flight features **drain** (finish the current phase, then halt) —
never killed mid-phase. The report shows `breaker_tripped: true` and lists
drained features under `not_started`. Raise the budget and re-run to continue.

---

## When a feature fails

`:failed` means a phase errored, the runner crashed/timed out, or the worktree
couldn't be created (missing scaffold — run `TargetPack.verify/1`). The worktree
is kept and its generated artifacts are committed to the branch. Inspect
`<transcript_root>/<feature_id>/` (or the worktree's `.speckit_logs/`), fix the
cause, and re-run (`resolve/1` first if a worktree/branch is in the way).

Common `:failed` / no-output causes seen in practice:
- **Phase action timed out.** Long phases (implement) need headroom;
  `config :jido_action, default_timeout` governs the action, kept below
  `FeatureRunner`'s outer call timeout.
- **Bash script denied.** The Spec Kit phase scripts run under Bash; the target
  pack's `settings.json` must allow `Bash`, and the phase must pre-approve it
  (specify/plan/tasks/implement/converge do — analyze is read-only by design).
