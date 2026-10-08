# Research: Container Workspace Trust (036)

All findings below were observed on 2026-10-08. Probes ran against the host
CLI **2.1.294** in an isolated `HOME` (scratch `~/.claude.json`, invalid API
key, so no session reached the API and nothing was spent). The container image
pins **2.1.286** (`Dockerfile` `CLAUDE_CODE_VERSION`); the smoke checks in
`contracts/container-trust-step.md` re-establish each finding inside the image,
which is the version the feature ships against.

## R1. How the CLI decides a workspace is trusted

**Decision**: Trust is a per-path record, `projects[<path>].hasTrustDialogAccepted:
true`, in the global CLI config (`~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`).
The key is the **canonical project root**, not the session's working directory:

| Trust record at | Session cwd | Warning? |
|---|---|---|
| none | target repo | yes |
| target repo | target repo | no |
| target repo | `<repo>/.claude` (subdir) | no |
| target repo | a `git worktree` of the repo under `$AUTONOMOUS_ROOT/worktrees/<seg>/` | **no** |
| instance worktree root | that worktree | **yes** |
| the worktree itself | that worktree | **yes** |
| `$AUTONOMOUS_ROOT` (an ancestor) | that worktree | yes |

For a git worktree, the CLI resolves the trust key to the **main repository**
(the warning itself names `projects["<target repo>"]` when run from a
worktree). A record for the worktree or for any of its ancestors is not
consulted.

**Rationale**: This confirms the spec's Assumption only in part: a record does
cover directories beneath it, but worktrees are keyed to the repository they
belong to, not to their location. The target-repo record is therefore the one
that makes every orchestrated session trusted — repo and worktrees alike.

**Consequence for the design**: The trust step still writes both records the
spec requires (FR-001, SC-002 "exactly 2"). The worktree-root record is
bounded (only this instance's worktrees live there), costs nothing, and covers
a future CLI that keys worktrees by their own path. The documentation states
plainly which record is load-bearing on the pinned CLI. The spec's fallback
("trust each worktree when it is created") is **not needed** and is not built:
it would mean the BEAM writing `~/.claude.json` while CLI sessions also write
it — the torn-file class feature 034 closed.

**Alternatives considered**:
- `CLAUDE_CODE_SANDBOXED=1` in the session env: the CLI then treats every
  workspace as trusted. Rejected — widens trust to every path (violates FR-003).
- Per-worktree records written by `Worktree.create/…`: rejected (above).

## R2. What an untrusted workspace loses

**Decision**: In 2.1.294 the trust-drop path is called for exactly two setting
kinds from `.claude/settings.json` / `.claude/settings.local.json`:
`permissions.allow` and `permissions.additionalDirectories`. The message is

```text
Ignoring <N> <kind> entr(y|ies) from <files>: this workspace has not been trusted. Run Claude Code interactively here once and accept the trust dialog, or set projects[<"path">].hasTrustDialogAccepted: true in <config file>.
```

It is written with `console.error` — **stderr**, once per dropped kind, at
settings load (before the first turn).

**Rationale**: Parser keys on the stable tail `this workspace has not been
trusted` and extracts the `projects[...]` key and `<kind>`/`<N>` when present.
The sibling message `a session with no working directory is never trusted.`
is also an untrusted signal (workspace = `nil`).

## R3. Does the scope_guard PreToolUse hook run while untrusted? (User Story 4, FR-010)

**Decision (provisional, host 2.1.294)**: **Yes** — project hooks run in an
untrusted workspace. Probe: a worktree whose `.claude/settings.json` carried a
`SessionStart` and a `UserPromptSubmit` command hook; both fired with no trust
record (warning present) and with trust (warning absent). The drop path in
R2 touches only the two permission kinds, not `hooks`.

**Rationale**: `SessionStart`/`UserPromptSubmit` load from the same settings
source as `PreToolUse`, and fire without an API call, so they are a zero-spend
proxy. A proxy is not proof for `PreToolUse` on the shipped 2.1.286, so the
documented finding comes from the smoke procedure `us-trust-hook`
(`quickstart.md` §4): a strict orchestrated-marker session in the image,
untrusted, asked to write outside the tree; observe the hook's deny line. It
costs a few cents and runs by hand (`SMOKE_AGENT=1`), like 034's agent check.

**Implication recorded in `docs/container.md`**: past containerized strict runs
kept their first containment layer (the hook); what they lost was the pack's
`permissions.allow` grants, i.e. they ran *narrower* than committed, not wider.

## R4. Where the orchestrator can see the warning

**Decision**: Inject an SDK `stderr` line callback per session.
- `ClaudeAgentSDK.Options` has `stderr: (String.t() -> any()) | nil`; without
  it the SDK logs each line as `Logger.warning("CLI stderr: …")` (which is how
  the operator saw the warning in `r000003`).
- `Jido.Claude.Adapter.build_options/2` merges `request.metadata["claude"]`
  into the `Options` attrs; `RunRequest.metadata` is `map(string, any)`, so a
  function value is accepted. `PhaseRequest.session_metadata/2` already uses
  this channel for `env` and `settings`.
- Today `SessionExit.classify/2` reads stderr **only** on session death, and
  `PhaseResult` drops unknown events: there is no capture path.

The callback must keep the existing log line (it replaces the SDK default), and
must record lines matching R2 into a per-session collector. The collector is
read after `PhaseSession.reduce/2` returns. Collector: a small process started
under `Autonomous.SessionSup` per session (a callback into a dead collector is
a no-op send), not the caller's mailbox — the action runs inside the Jido
`AgentServer`, whose mailbox the orchestrator does not own.

**Alternatives considered**:
- A global `Logger` handler matching `CLI stderr:` lines: cannot attribute a
  line to a session or phase; rejected.
- Reading `~/.claude.json` before each session to predict trust: duplicates
  the CLI's resolution rules (R1) — a guess about an external contract,
  forbidden by Principle I. The CLI's own report is the source of truth.

## R5. Gate placement and retry

**Decision**: New reason `{:untrusted_workspace, phase, %{workspace: path | nil,
kinds: [String.t()]}}`.
- Extracted upstream (session-driving site), passed to `Pipeline.next/3` as a
  signal **only when the run's profile is `strict`**; under `permissive` the
  site logs a warning naming the workspace and passes no signal. `Pipeline`
  stays profile-agnostic and pure.
- Order in `Pipeline.next/3` `:error`/`:ok` handling: branch-drift →
  session-died → **untrusted-workspace** → backgrounded → incomplete-session →
  generic. Branch drift and session death describe a session that did not
  happen as expected; untrusted describes how the session ran, and outranks
  the remaining gates because it is the root cause they would otherwise mask.
- Applies even when the session status is `:ok` (the pack was partly ignored
  regardless of outcome).
- Never retried: `PhaseStep.retry_reason/1` returns `nil` for it (same short
  circuit as branch drift); `SessionRetry.once/2` and `Chunking`'s
  died-retry do not fire on it. A retry would start another untrusted session
  — deterministic, not transient.
- Applied at every session-driving site: `RunFeaturePhase`,
  `RunAutoRemediation`, `RunRemediation`, `ChunkRunner`/`Chunking`,
  `AnalyzeRunner`, `FeatureRunner.remediation_failure_reason`.

**Constitution note**: Principle III lists the gates that MUST behave
identically under both profiles (branch drift, artifact substance, incomplete
session, analyze, clarify). This gate is not a correctness gate; it reports
whether the committed pack was applied, which is a containment concern, so the
profile governs it (spec Clarifications 2026-10-08). No principle is amended.

## R6. Container trust step mechanics

**Decision**: A `trust_workspaces` step in `scripts/container-entrypoint.sh`,
run after the identity is exported and after `seed_cli_config` (4b), before
any VM or CLI process starts. Implemented in inline `python3` (present in both
the dev and release images via `base`; already used by the entrypoint):

1. Paths: `os.path.realpath($AUTONOMOUS_REPO)` and
   `os.path.realpath($AUTONOMOUS_WORKTREE_ROOT)` (realpath of a not-yet-existing
   root resolves the existing prefix; the CLI keys canonical paths).
2. Read `$HOME/.claude.json` if present. Not valid JSON, or not an object, or
   `projects` present and not an object ⇒ exit non-zero naming the file;
   never overwrite (FR-008). Absent ⇒ start from `{}`.
3. For each of the two paths set `projects[p].hasTrustDialogAccepted = true`,
   keeping every other key of that project entry and of the file.
4. If nothing changed, do not write (idempotent, byte-identical — FR-006).
5. Otherwise write `<file>.tmp.<pid>` with `O_CREAT|O_EXCL`, mode `0600`,
   `fsync`, then `os.replace` (atomic — FR-005).

The host config is never a target: the seed mount is read-only and the step
writes only `$HOME/.claude.json` inside the container (FR-007).

A `trust-config` entrypoint subcommand (sibling of 034's `seed-config`) runs
seed + trust and exits, for the hermetic test and the smoke checks.

**Alternatives considered**: `jq` (not in the image); an Elixir step in the
release/boot path (too late — `shell`/`console` sessions can start as soon as
the VM is up, and the BEAM would race the CLI on the file).

## R7. Where the worktree root comes from

**Decision**: `Autonomous.Instance.env_lines/1` gains
`AUTONOMOUS_WORKTREE_ROOT=<autonomous_root>/worktrees/<segment>`, computed by
the same function `Layout` uses (extract `Layout.worktree_root/2`), so the
entrypoint never recomputes layout (the entrypoint's own rule: identity is
derived only in Elixir). The 031 environment contract's five identity
variables become six.

## R8. Host behaviour

**Decision**: No trust write on the host (FR-012). The untrusted gate (R5)
applies on the host too: a strict host run against a target the operator never
trusted fails its first phase with `{:untrusted_workspace, …}`, and the
rendered reason tells the operator the fix — trust the target repository once
(interactive `claude` in it, accept the dialog). Per R1 that one record covers
every worktree, so no per-worktree action is needed.

## Implementation note (US1): stderr capture path

The pinned `Jido.Claude.Adapter` whitelists forwarded option keys (`@option_keys`)
and drops `:stderr`, so `metadata["claude"][:stderr]` (contracts/untrusted-workspace-gate.md §2)
never reaches the SDK. Capture instead goes through `Autonomous.SdkProxy`
(`config :jido_claude, sdk_module:`): `PhaseRequest` carries the collector pid in the
request env under `AUTONOMOUS_STDERR_COLLECTOR`; the proxy strips it, installs the
callback (same `CLI stderr: …` log as the SDK default) and delegates to `ClaudeAgentSDK`
(`config :autonomous, :sdk_proxy_inner` overrides the delegate in tests). Chosen with the
operator over bumping the dep.

## Quickstart walk-through notes (2026-10-08)

- §5 was run on a never-trusted scratch target. `Autonomous.run/1` refuses to boot on the host (`ContainerGuard`), so the driver started the app with `require_container: false` (as the test config does) and a throwaway `AUTONOMOUS_STORE_DIR`. Strict: `specify` failed with `untrusted_workspace`, one attempt, matching report text ($0.27). Permissive: `Logger.warning("untrusted workspace …")` on specify/clarify/plan, run proceeded until the $1 breaker. Trusted (temp `HOME` with the record): specify and clarify ran with no untrusted line.
- §6: the host `~/.claude.json` hash changed during the walk because the operator's own Claude Code session writes it; the check needs an idle host CLI. Covered by the `trust` smoke section (seed file sha256 unchanged).
- With `--with-login`, each restart re-seeds `~/.claude.json` from the host file before the trust step, so the container file is rewritten per start (never reports "already trusted"); idempotence holds when the host file is stable.
