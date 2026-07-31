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

## Run directory layout (012, store 018)

Working data lives in two places, keyed by **repository identity**
(`<repo-name>-<shorthash>`, derived from the target's `origin` remote — a repo
with no `origin` falls back to a local-path-derived id, `l:...`) and **run
scope** (a breakdown package slug, or the literal `ad-hoc`):

```text
~/.autonomous/                                  # config :autonomous_root (machine-global; default ~/.autonomous)
├── worktrees/<repo-name>-<shorthash>/<feature_id>-<slug>/   # per-feature git worktrees
└── mnesia/                                      # config :store_dir — the ONE durable record (018)
                                                   # runs, features, phase attempts, checkpoints,
                                                   # escalations, remediation attempts, transcripts —
                                                   # everything the old run.json/checkpoint.json/
                                                   # NN-<phase>.md/pr.json files used to hold

<target_repo>/specs/autonomous/                 # config :specs_root (in-repo, committed)
├── breakdown/<breakdown-slug>/NNN-slug.md       # feature files, one dir per package (§3)
└── ad-hoc/NNN-slug.md                           # single-spec-run seeds
```

**Nothing durable lives on disk under a feature id or a phase name anymore.**
Every phase attempt, checkpoint, escalation, remediation attempt, and
transcript is a row in the Mnesia store at `store_dir` (default
`~/.autonomous/mnesia`) — read it through
`SpeckitOrchestrator.{run_history/1, run_detail/1, transcript/1}` or the
console's `/runs` and `/runs/:run_id` views (see "Run history & detail" below),
never by grepping a file. The worktree itself still exists on disk (kept for a
non-`:done` outcome, removed on `:done`) but carries no state the orchestrator
reads back.

A **breakdown run** (`SpeckitOrchestrator.run/1`) selects one package by
`:slug`/`:package` opt, or — with none given — the sole package directory
under `specs/autonomous/breakdown/`; two or more with no selection is refused
loud (`{:error, {:preflight, {:ambiguous_breakdown_package, slugs}}}`). The
Trigger console view (`/trigger`) lists available packages and lets the
operator pick one before starting. A package literally named `ad-hoc` is
rejected (it would collide with the ad-hoc transcript segment).

A **single-spec run** (`SpeckitOrchestrator.run_spec/2`) is always ad-hoc
scope — its seed lands under `specs/autonomous/ad-hoc/`, never inside any
breakdown package, and its transcripts key off the literal `ad-hoc` segment.

**Migration note.** Nothing under the old paths (`../.speckit-worktrees`,
`<repo>/.speckit-transcripts`, `docs/breakdown`, and — pre-018 — `run.json`/
`checkpoint.json`/`NN-<phase>.md`/`pr.json` under `~/.autonomous/transcripts/`)
is moved, copied, or deleted — the new layout applies only to runs started
after upgrading. **Drain in-flight runs before upgrading**: a run's state
written under the pre-018 file scheme cannot be resumed once the store
replaces it (FR-037, clean break — no migration path). Pre-existing files
under the old paths may be deleted by hand once every run is drained; the
orchestrator never reads them.

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

Put `NNN-slug.md` files in the target under `specs/autonomous/breakdown/<slug>/`
— `<slug>` is the package directory name (`run/1` selects a package by this
slug; see "Run directory layout" above). Each needs a `## Prerequisites`
section (drives the DAG). **A breakdown that delegates a decision the sources
can't answer will stall `plan`/`clarify` — see "Decide the tech stack" below.**

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

```bash
SPECKIT_REPO=../ledgerlite iex -S mix
```

```elixir
iex> SpeckitOrchestrator.Telemetry.attach_default_logger()   # log phase transitions
iex> {:ok, _coord} = SpeckitOrchestrator.run()
```

`run/0` loads the backlog, validates the DAG (raises on cycles / dangling
prereqs), and releases the first wave. Features run in dependency-and-cap waves
(`config :max_concurrency`). The caller receives `{:run_complete, report}` when
the run drains.

**Environment variables** (`config/runtime.exs`) are read at boot in every env
except `:test`, so they steer a plain `iex -S mix` as well as a release:

| Variable | Effect |
|----------|--------|
| `SPECKIT_REPO` | Target repo. Required in `:prod` (raises at boot if unset); elsewhere overrides the `repo: "."` default. **Unset means the orchestrator points at itself and finds no backlog** — the console's package pickers then render empty. |
| `SPECKIT_PR_WORKFLOW` | `true` → stacked sequential PR run: cap 1, remote preflight, one stacked PR per feature on `:done`. |
| `SPECKIT_PR_BASE` / `SPECKIT_PR_REMOTE` | Root base branch / remote for the PR stack (default `main` / `origin`). |
| `SPECKIT_MAX_CONCURRENCY` | Wave cap. Ignored under the PR workflow, which pins 1. |
| `SPECKIT_BUDGET_USD` | Cost breaker budget. |
| `SPECKIT_PLAN_STACK` | Preferred stack handed to `plan` (see step 5). |

**More than one breakdown package.** With 2+ packages under
`specs/autonomous/breakdown/`, a bare `run/0` refuses rather than guessing:

```elixir
iex> SpeckitOrchestrator.run()
{:error, {:ambiguous_breakdown_package, ["001-mvp", "002-addons"]}}

iex> SpeckitOrchestrator.run(slug: "001-mvp")
```

The console's Trigger Run page supplies this from its package picker.

---

## Single-spec run (no backlog required)

To drive **exactly one** feature from a free-text description — no
`specs/autonomous/breakdown/<slug>/NNN-slug.md` file to author, no
prerequisites to declare — use
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
- **Transcripts live in the store, not on disk (018).** Every phase attempt's
  transcript survives worktree teardown on `:done`, retrievable on demand:
  ```elixir
  {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
  attempt = detail.features |> Enum.find(& &1.feature_id == "003") |> Map.fetch!(:phase_attempts) |> List.last()
  {:ok, %{body: body}} = SpeckitOrchestrator.transcript(attempt.transcript_ref)
  ```
  or browse them in the console's run detail view (`/runs/:run_id`) or the
  Transcripts view (`/transcripts`) — never by reading a file.
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

If plan/tasks/implement produced nothing, read that phase's transcript for the
blocker — usually a missing tech stack or a Bash approval denial:

```elixir
{:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
plan_attempt = detail.features |> Enum.find(& &1.feature_id == "NNN") |> Map.fetch!(:phase_attempts) |> Enum.find(& &1.phase == :plan)
{:ok, %{body: body}} = SpeckitOrchestrator.transcript(plan_attempt.transcript_ref)
IO.puts(body)
```

or open `/runs/:run_id` in the console and expand the feature's `plan` attempt.

---

## Respond to an escalation

A feature that emits the `## NEEDS HUMAN` heading at `clarify` ends `:escalated`;
its worktree is **kept**. The report lists it under `escalated` and its
dependents under `blocked`.

**Escalations can span multiple rounds** — answering one round's questions can
expose the next round's second-order questions (e.g. deciding a date sort key
opens "does `add` take a date input?"). This is the gate converging, not a
failure.

1. **Read the escalation.** The clarify transcript (via `transcript/1`/the
   console's `/runs/:run_id` or `/escalations` view — see "Watch a run" above)
   and the spec's `## NEEDS HUMAN` section. Each item lists a precise question
   and the options considered.
2. **Answer in the BREAKDOWN, not just the spec.** A re-run's `specify`
   regenerates `spec.md` from the breakdown, so spec-only edits are discarded.
   Put the decisions in `specs/autonomous/breakdown/<slug>/NNN-slug.md` under a `## Decisions`
   section (the parser ignores everything but `## Prerequisites`, so this is
   safe). Make each decision specific and testable.
3. **Commit on the feature branch** (`feature/NNN-slug`) — the kept worktree is
   already on it:
   ```bash
   git -C <kept-worktree> add specs/autonomous/breakdown/<slug>/NNN-slug.md && git commit -m "resolve H-… for NNN"
   ```
4. **Free the worktree** (the branch commit is preserved):
   ```elixir
   iex> SpeckitOrchestrator.resolve("NNN")
   ```
5. **Re-run** `SpeckitOrchestrator.run()`. The feature reuses its branch and
   re-runs from the start. For a targeted restart at the checkpointed phase
   instead, see "Resume a halted/escalated feature (mid-pipeline)" below.
   With the decisions now in the breakdown, `clarify` should default/resolve
   and its dependents unblock. If a **new** round of questions appears, repeat
   1–5.

---

## Auto-remediation and the exhaustion policy (017, 021)

Before the `analyze` gate decides, a bounded corrective loop MAY retry
findings at or above a configured severity threshold (default High), up to a
per-run attempt limit (default 2). The Trigger Run page's **Analyze
auto-remediation** control group sets this per run: the switch, the severity
threshold, the attempt limit, and — as of feature 021 — **On exhaustion**, a
fourth control choosing what the gate does if the loop spends its full
attempt budget and a High finding is still there:

- **escalate** (default) — the feature ends `:escalated`, exactly as it would
  with the loop off. Nothing about this changes.
- **proceed** — the feature advances past the residual finding instead, and
  finishes the pipeline unattended. What it advanced past is recorded and
  surfaced in three places: the run's final report (an `advanced: NNN, …`
  line), the console's `/runs/:run_id` feature panel (an "Advanced with
  unresolved findings" block, listing the policy, attempts consumed, and each
  finding), and the feature's pull request body (an "Advanced with unresolved
  analyze findings" section naming the same findings). **Review that PR
  section before merging** — the findings are unresolved in the branch by
  definition, and this is the last point a human sees them.

Critical is unaffected by this control in every case: it halts unconditionally
(`:halted`), regardless of the exhaustion policy or the severity threshold.

`iex`-driven runs pass the equivalent opt:

```elixir
iex> SpeckitOrchestrator.run(auto_remediation_exhaustion_policy: :proceed)
```

An unrecognized value (either surface) is refused before any run starts — no
`Coordinator`, no store row — naming `auto-remediation-exhaustion-policy` as
the offending setting. A run started with nothing set, or with `:escalate`
explicit, behaves byte-for-byte like a run before feature 021 existed; the
default never changes just because a previous run chose `:proceed` (each
launch re-reads the configured default).

---

## Resume a halted/escalated feature (mid-pipeline)

`SpeckitOrchestrator.resume/2` restarts a previously-escalated or halted
feature at its checkpointed phase, reusing (or recreating) its existing
branch — the mid-pipeline counterpart to `resolve/1`'s full restart from
`specify`.

1. Fix the root cause on the feature branch (the same worktree/branch
   `resolve/1` would target) and commit.
2. Resume from the checkpointed phase:
   ```elixir
   iex> SpeckitOrchestrator.resume("003")
   ```
   By default this restarts at whichever phase was checkpointed when the
   feature last halted or escalated — not from `specify`.

### Options

- `:prompt` — inject operator guidance into the resumed phase as
  `resume_prompt`:
  ```elixir
  iex> SpeckitOrchestrator.resume("003", prompt: "use Decimal for money, not float")
  ```
- `:from` — override the start phase, restarting earlier than the checkpoint.
  Reach for this when the fix touches an upstream artifact the checkpointed
  phase alone won't pick back up:
  ```elixir
  iex> SpeckitOrchestrator.resume("003", from: :plan)
  ```
- Both together:
  ```elixir
  iex> SpeckitOrchestrator.resume("003", from: :plan, prompt: "re-plan around the money fix")
  ```

`resume(id)` alone is the canonical, self-sufficient form: identity (`slug`,
`path`) is recovered from the checkpoint itself, so no hand-typed `%Feature{}`
and no loadable backlog are required. Passing `:features` (an explicit list,
or a working `load_backlog/0`) still works and takes precedence over
checkpoint identity when both name the same id — kept for backward
compatibility, not required for a normal resume.

All other options (`:runner`, `:owner`, `:max_concurrency`, …) pass through
unchanged to `run/1`; a caller-supplied `:runner`/`:executor` wins over the
injected resume runner/executor.

### Run context reapply

The checkpoint also records the run-shaping settings in effect when the
feature was originally started — `pr_workflow`, `max_concurrency`,
`budget_usd`, `plan_stack`, `pr_base`, `pr_remote` — and `resume/2` reapplies
them, so a resumed run re-executes under its original shape even if the live
environment/Config has since changed (e.g. `pr_workflow` was on for the
original run but is off by default now). Precedence, fixed:

**explicit `resume/2` option > recorded checkpoint context > live Config/default**

```elixir
# Checkpoint recorded pr_workflow: true — resume routes through the stacked
# PR-workflow executor (cap 1, stacking, PR-on-:done) even if the live
# Config default is off:
iex> SpeckitOrchestrator.resume("003")

# Override deliberately — explicit opt beats the recorded value:
iex> SpeckitOrchestrator.resume("003", pr_workflow: false)
```

A setting missing from the checkpoint (old checkpoint written before this
feature, or a partial record) falls back to live `Config` and logs which
settings fell back:

```text
feature 003 resume: no recorded context for [:max_concurrency, :budget_usd, :plan_stack, :pr_base, :pr_remote] — falling back to live Config
```

No crash either way — a resume never fails because context is missing, only
because identity/checkpoint/phase is invalid (see the table below).

### `resolve/1` vs `resume/2`

- Use **`resume/2`** when a checkpoint exists and the fix is local to one
  phase's inputs — it restarts only the checkpointed (or `:from`-overridden)
  phase, not the whole pipeline.
- Use **`resolve/1`** when the fix must regenerate upstream artifacts (e.g.
  `spec.md` itself, via a `specs/autonomous/breakdown/<slug>/NNN-slug.md` decision — see
  "Respond to an escalation" above), or when the checkpoint is missing or
  corrupt.

`resume/2` never starts a run on an unsafe precondition — each case fails
closed with a distinct error and no run:

| Returned | Meaning |
|----------|---------|
| `{:error, {:unknown_feature, id}}` | feature id not in the backlog |
| `{:error, :no_checkpoint}` | feature never checkpointed → use `resolve/1` |
| `{:error, :corrupt_checkpoint}` | checkpoint unreadable → use `resolve/1` |
| `{:error, {:unknown_phase, term}}` | bad `:from` (or corrupt stored phase) |

---

## Resume a whole crashed run

`resume/2` above fixes one feature. If the orchestrator process itself
crashed (BEAM node died, machine restarted) mid-run, the whole backlog needs
reconstructing: some features `:done`, one `:running` when the crash hit, the
rest still `:pending`. That's what `SpeckitOrchestrator.resume_run/1` and
`resumable_run/0` are for.

Recovery relies on the one durable store record (018) — every phase attempt,
checkpoint, escalation, and remediation attempt for the run — plus git commits
in each feature's worktree/branch as corroborating evidence
(`Recovery.reconcile_run/2`). There is no separate on-disk manifest/checkpoint
file to go stale or disagree with the store; a disagreement between the store
and git evidence surfaces as a `Recovery.Report` conflict rather than being
resolved silently.

**Per-phase checkpoint + commit.** `FeatureRunner` records a checkpoint
(`status: :in_progress`, `last_completed_phase:` the phase that just
finished) in the same store transaction as the phase attempt, and commits the
worktree, after **every** phase — not only on a gate divert. On `:done` those
per-phase commits are squashed into one clean commit (`Worktree.squash/3`); a
kept terminal (`:escalated`/`:halted`/`:failed`) keeps them as the post-mortem
trail.

**Operator flow (boot → detect → resume):**

1. **Detect.** After a crash, before touching anything, check whether a run
   is resumable — this starts no work:
   ```elixir
   iex> SpeckitOrchestrator.resumable_run()
   {:ok, %{report: %{...}, statuses: %{...}, resume_phases: %{...}, gap_possible?: false}}
   # or :none — every feature was already terminal/diverted, nothing to resume
   # or {:error, :no_manifest} / {:error, :corrupt_manifest}
   ```
   `gap_possible?: true` means a persistence-failure halt may have left the
   record incomplete (see "Persistence failure" below) — the same crash, plus
   a warning to double-check evidence against the store before trusting it.
2. **Resume explicitly.** Recovery is operator-initiated — it is never
   triggered automatically on boot, because resuming spends money (FR-014):
   ```elixir
   iex> SpeckitOrchestrator.resume_run()
   {:ok, coordinator_pid}
   ```
   This reconstructs `{features, statuses}` from the store's run record —
   `:done` and gate-diverted features are kept as-is and never re-run;
   `:running` (interrupted) and `:pending` (never released) features reset to
   `:pending` and release in the normal dependency-and-cap order. A
   checkpointed feature resumes at the phase after its
   `last_completed_phase` (reusing `resume/2`'s machinery internally,
   including `Worktree.restore/1` to discard any uncommitted partial output
   the crash left behind); a never-started feature runs fresh from `specify`.
   Continues the **same `run_id`** — never opens a new run, so spend stays
   attributable across the resume.
3. **Cost continuity.** Before any wave releases, `resume_run/1` restores the
   `Ledger`'s committed spend from the run's recorded cost-entry roll-up
   (FR-012) — never from zero. If the restored figure is already at/above
   budget, the breaker is treated as tripped and the resumed run releases
   **zero** new features (drain, not kill — same invariant as a live breaker
   trip).
4. **Run-shaping context.** The resumed run re-executes under the store's
   recorded `pr_workflow`/`max_concurrency`/`budget_usd`/`plan_stack`/
   `pr_base`/`pr_remote` (captured once at `open_run`, in `speckit_run_settings`
   — not re-recorded on every checkpoint), not live `Config` defaults — same
   explicit-opt > recorded > live-Config precedence as `resume/2` (FR-007).
5. **Guard against clobbering a live run.** If a `Coordinator` is already
   alive and unfinished, `resume_run/1` refuses:
   ```elixir
   iex> SpeckitOrchestrator.resume_run()
   {:error, {:active_run, #PID<0.123.0>}}
   ```
   Pass `force: true` only when you're certain the live process is stuck, not
   genuinely still working.

**Supersession, not a single slot.** A fresh `run/1` opens a new store record
and supersedes whatever prior in-flight run exists for the same repository
(`FR-023/FR-034`) — the superseded run's non-terminal features are marked
`:ended_by_supersession` and the run itself stays in the store, retained and
distinguishable from a normal completion. Unlike the pre-018 single manifest
slot, **every prior run is retained** — see "Run history & detail" below to
review any of them, not only the most recent.

For the single-feature case (one feature stuck, rest of the run fine), reach
for `resume/2` (previous section) instead of `resume_run/1` — restarting the
whole run to fix one feature is unnecessary churn.

### Persistence failure (018)

If the store itself becomes unwritable mid-run (disk full, permissions
changed), the run **drains, never kills mid-phase**: the in-flight phase
finishes, its result is attempted-written, and only then does the feature halt
with a persistence-failure reason — the same drain-don't-kill invariant the
cost breaker uses. Check `Store.Health.status/0` to see a failure the moment
it's recorded:

```elixir
iex> SpeckitOrchestrator.Store.Health.status()
{:failed, reason, at}   # or :ok
```

`run_history/1` shows a run drained this way with `record_complete?: false`,
and `resumable/1`'s `gap_possible?: true` flags it on the next resume. Restore
writability, then `resume_run/1` continues the same run id from its last
recorded position.

---

## Parked runs (019)

Every run is a single stacked sequential chain — one feature at a time, in
ascending numeric order. When a feature reaches a non-done terminal state
(`:escalated`/`:halted`/`:failed`) and nothing else is in flight, the chain
**stops** and the run is **parked**: `:in_flight -> :parked`, recording which
feature stopped it and why (`stopped_by`/`stopped_reason`). This is distinct
from a cost-breaker drain (which still leaves the run `:in_flight` for
`resume_run/1`, unchanged from before) — parking is specifically the
stop-on-first-broken-link outcome, and it is never automatic to resolve:
the system never decides on the operator's behalf.

**A parked run blocks new work for its repository.** Both `run/1` and
`run_spec/2` refuse while one exists, naming it and both ways out:

```elixir
iex> SpeckitOrchestrator.run()
{:error, {:parked_run, "r000007", [:continue, :end]}}
```

**Resolve it — pick one:**

1. **Continue** the chain — re-runs the stopping feature at its checkpointed
   phase (same machinery as `resume/2`), then releases the remainder in
   order, under the **same `run_id`**:
   ```elixir
   iex> SpeckitOrchestrator.continue_run()
   {:ok, coordinator_pid}
   # or {:error, :no_parked_run} / {:error, {:active_run, pid}} / a preflight error
   ```
   Accepts the same per-feature options as `resume/2` (`:prompt`, `:from`,
   `:remediation_prompt`, `:remediation_model`, `:from_task_phase`, `:force`),
   plus every `run/1` option except the two retired ones. If the stopping
   feature breaks again, the run parks a second time with the new reason
   recorded distinctly from the first.
2. **End** the chain — closes the run out without releasing anything further:
   ```elixir
   iex> SpeckitOrchestrator.end_run()
   {:ok, run_summary}
   # or {:error, :no_parked_run}
   ```
   `state: :parked -> :completed`, `outcome: :ended_by_operator`; every
   still-`:pending` feature is written `:never_started` in the same
   transaction. `stopped_by`/`stopped_reason` are retained, so the closed
   record still says what stopped the chain. `run/1` for the repository is
   accepted again immediately afterward.

**Via `resolve/2`.** When the repository has a parked run, `resolve/2` gains
a required `:decision`, frees the stopping feature's worktree and records its
escalation resolution first, then dispatches to whichever of the above you
chose:

```elixir
iex> SpeckitOrchestrator.resolve("003", decision: :continue)
iex> SpeckitOrchestrator.resolve("003", decision: :end)
iex> SpeckitOrchestrator.resolve("003")
{:error, :decision_required}   # nothing changes — the choice is never made for you
```

With no parked run, `resolve/1` behaves exactly as before and `:decision` is
not required.

**In the console**, Mission Control (`/`) shows a parked banner naming the
stopping feature and reason with both actions as buttons; Run History (`/runs`)
and Run Detail (`/runs/:id`) render `:parked` distinctly from `:in_flight`/
`:completed` and list never-started features as such.

### Store reset procedure (schema v1 -> v2)

019 bumps the store schema `1 -> 2` as a **clean break** — a v1 directory
aborts startup naming the incompatibility rather than being migrated (there is
no compatibility path). Before upgrading:

```bash
# 1. Export anything worth keeping from the v1 store, BEFORE upgrading.
mise exec -- iex -S mix
iex> SpeckitOrchestrator.export_run("r000007", "/tmp/r000007.json")

# 2. Upgrade, then remove the v1 store directory.
rm -rf ~/.autonomous/mnesia

# 3. Start. A fresh v2 schema is created; the next run is run number one.
```

See `specs/019-stacked-sequential-only/contracts/store-schema-v2.md` § 6 for
the full contract.

### "unmigrated_schema" — recompiled under a running node

```
{:damaged, {"o:repo", "r000001", "002"}, {:unmigrated_schema, :speckit_feature_run, [...15], [...14]}}
```

Nothing is corrupt. `Schema` gained an attribute and the project recompiled, so
the running node expects a shape the tables on disk do not have — no reboot, so
no migration ran. In dev this needs no deliberate act: recompiling is enough for
the code reloader to swap `Schema` in, and every read of that table then fails
against intact rows. A live run can lose features to it.

**Restart.** `Store.Boot` applies the pending migration and the reads recover.
Nothing to export, nothing to delete.

`Store.Boot.verify_table_shapes/0` runs after migrations and refuses to finish
booting on a disagreement (`{:schema_shape_mismatch, table, expected, actual}`),
which catches the other cause: an attribute added to `Schema` with no migration
written to carry existing tables to it. If a restart aborts with that, the fix is
a migration, not a reset.

### Recording a PR the run didn't record

A `:done` feature whose drawer shows **"No PR recorded"** either had its
publish fail, or was built before `pr_url` was persisted at all. The publish
step is the only thing that writes that field automatically, so once the run
has moved on, an operator has to supply it:

```elixir
SpeckitOrchestrator.record_pr("001", "https://github.com/you/repo/pull/6")
SpeckitOrchestrator.record_pr("001", url, run_id: "r000001")   # an older run
```

The default targets the repository's **current in-flight** run; a completed or
parked run returns `{:error, :no_run}` and needs the explicit `run_id:`. The
call emits the same `[:speckit, :publish, :opened]` event the live path does,
so an open console updates the drawer immediately — no reload.

A publish that fails for a branch the orchestrator itself pushed no longer
needs this: `Worktree.push/2` prunes deleted remote branches and replaces its
own stale branch with `--force-with-lease`. It still refuses — loudly, as
`{:remote_branch_moved, branch, sha}` — when the remote branch moved outside
this repo, since that is someone else's commit.

### Schema v3 — no reset needed

v3 appends `feature_run.pr_url` so a `:done` feature's drawer can link to the
PR that was opened for its branch. A **v2 directory migrates in place at
boot** — nothing to export, nothing to remove. Rows written before the upgrade
keep `pr_url: nil` and their drawer shows "No PR recorded" rather than a link;
features published after it link straight to the PR.

---

## Run history & detail (018)

Every run for a repository is retained, successful or not — review any of them
without a live `Coordinator`, from `iex` or the console.

```elixir
{:ok, runs} = SpeckitOrchestrator.run_history()
Enum.map(runs, &{&1.run_id, &1.state, &1.outcome, &1.spend_usd})
# most recent first

SpeckitOrchestrator.run_history(outcome: [:halted, :escalated])
SpeckitOrchestrator.run_history(feature: "003")

{:ok, d} = SpeckitOrchestrator.run_detail("r000004")
f = Enum.find(d.features, & &1.feature_id == "003")
f.phase_attempts       # execution order, with outcome/model/cost/duration
f.escalations          # reason, originating phase, triggering evidence
f.remediation_attempts # each attempt, with the limit and threshold in force

{:ok, %{body: body}} = SpeckitOrchestrator.transcript(List.first(f.phase_attempts).transcript_ref)
```

In the console: `/runs` lists history (state badge, outcome, spend, per-feature
status chips, filters by outcome/feature); `/runs/:run_id` shows one run's full
detail — settings and amendments, per-feature phase attempts, escalations,
remediation attempts, and on-demand transcripts — plus **export** and
**resolve escalation** actions. The existing views (`/`, pipeline DAG,
escalations, transcripts) render the same store-sourced facts.

### Store capacity and pruning

The store has a capacity ceiling (`config :store_capacity_bytes`, default
1.5 GB) with headroom (`config :store_headroom_bytes`, default 150 MB).
Check it any time:

```elixir
iex> SpeckitOrchestrator.store_capacity()
%{status: :ok, used_bytes: _, capacity_bytes: 1_500_000_000, shortfall_bytes: nil, reclaimable_bytes: _}
```

A `run/1`/`resume/2`/`resume_run/1` refuses **before spending anything** when
headroom is gone:

```elixir
iex> SpeckitOrchestrator.run()
{:error, {:preflight, [{:store_capacity, %{shortfall_bytes: _, reclaimable_bytes: _}}]}}
```

Nothing else is affected by a capacity refusal — history, detail, transcript
retrieval, export, and prune all keep working, and any in-flight run is
untouched. Hitting the ceiling **mid-run** (not at preflight) is a write
failure, not a refusal — it drains the same way persistence failure does
(above), discarding nothing.

**Pruning is the only mechanism that deletes recorded state**, and it's always
operator-initiated — preview first, confirm explicitly:

```elixir
{:ok, plan} = SpeckitOrchestrator.prune_preview(before: ~U[2026-06-01 00:00:00Z])
plan.removable          # what would go
plan.retained           # in-flight / resumable runs, each with a reason — never removed
plan.bytes_reclaimable

{:ok, res} = SpeckitOrchestrator.prune(before: ~U[2026-06-01 00:00:00Z], confirm: true)
```

A resumable run (in-flight, or with an open escalation/halt) is never removed
regardless of the boundary; `prune_preview/1` performs nothing on its own.

### Export

```elixir
{:ok, path} = SpeckitOrchestrator.export_run("r000004", "/tmp/r000004.json")
```

One self-describing JSON file: every feature, phase attempt, escalation,
remediation attempt, setting, cost entry, and transcript, recoverable from
that file alone with zero external references (transcript bytes round-trip
byte-identically, including non-UTF-8 bodies via `"encoding": "base64"`).
Read-only — works mid-run and under a capacity refusal, and changes nothing in
the store.

### Node-name failure mode

The store is a single-node Mnesia schema, keyed to the node name that created
it. Starting the orchestrator under a **different** node name than the one
that created the schema is a **hard failure that names both names**, not a
silent new (empty-looking) store:

```elixir
{:error, {:schema_node_mismatch, expected: node(), schema: [...]}}
```

The app does not boot. This is deliberate (Constitution Principle II) — a
foreign schema silently presenting as "no history" would be exactly the kind
of silent data loss the store exists to prevent. If you see this, you're
running with a different `--name`/`--sname` (or none) than whichever process
created `store_dir`; start with the same node name, or — only if you're
certain the old store is truly abandoned — move `store_dir` aside by hand.

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
is kept and its generated artifacts are committed to the branch. Inspect the
feature's phase attempts and transcripts via `run_detail/1`/`transcript/1` (or
the console's `/runs/:run_id`), fix the cause, and re-run (`resolve/1` first
if a worktree/branch is in the way).

Common `:failed` / no-output causes seen in practice:
- **Phase action timed out.** Long phases (implement) need headroom;
  `config :jido_action, default_timeout` governs the action, kept below
  `FeatureRunner`'s outer call timeout.
- **Bash script denied.** The Spec Kit phase scripts run under Bash; the target
  pack's `settings.json` must allow `Bash`, and the phase must pre-approve it
  (specify/plan/tasks/implement/converge do — analyze is read-only by design).
- **A phase refused and asked a question.** See the artifact gate below.

---

## Artifact & converge gates (no-op phase detection)

A phase can return a *perfectly successful* transcript while writing **nothing**:
it refused, asked a clarifying question no one can answer headlessly, or no-opped
because an upstream artifact was missing. Without a filesystem check the pipeline
marches on and opens a PR for an unbuilt feature — every downstream phase
reporting the problem in prose that nobody reads.

Two deterministic gates close this:

| Gate | Check | Terminal |
|------|-------|----------|
| artifact | after `plan` → some `specs/**/plan.md` exists; after `tasks` → `specs/**/tasks.md`; after `implement` → the worktree has changes **outside** `specs/`, `.specify/`, and the log dirs | `:failed`, reason `{:missing_artifact, phase, what}` |
| converge | converge's last line is `## CONVERGE: NOT READY` | `:failed`, reason `:converge_not_ready` |

Both keep the worktree for post-mortem. `analyze` also escalates on a `high`
finding now (`:escalated`, reason `:high_findings`); `critical` still halts.

**The most common trigger — a contradictory `plan_stack`.** If the stack handed
to `plan` conflicts with the target's own constitution/manifest (e.g. a Python
stack against a Phoenix repo), plan will refuse and ask which to use, then write
no `plan.md`. Leave `SPECKIT_PLAN_STACK` **unset** so plan derives the stack from
the target itself; set it only for a target whose spec deliberately leaves the
stack open:

```bash
export SPECKIT_PLAN_STACK="Python 3 (standard library only: argparse, unittest)"
```

Read the feature's `plan` transcript (`transcript/1`, or `/runs/:run_id` in the
console) to see exactly what plan said.
