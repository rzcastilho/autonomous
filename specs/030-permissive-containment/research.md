# Research: Permissive Containment Profile

Feature: `030-permissive-containment` | Date: 2026-09-28 | Spec: [spec.md](spec.md)

Every decision below was checked against the code at `df4b6f3` and the pinned
deps (`deps/jido_claude`, `deps/claude_agent_sdk`). Items marked **verify at
implementation** are facts about the external `claude` CLI that this plan
relies on but could not prove from source alone.

---

## R1 — Where today's denials actually come from

**Decision**: Treat the pack as having **two** denial sources, and move both
into the hook:

1. `priv/target_pack/.claude/settings.json` → `permissions.deny`:
   `Bash(sudo:*)`, `Bash(git push:*)`, `Bash(curl:*)`, `Bash(wget:*)`,
   `WebFetch`, `WebSearch`.
2. `priv/target_pack/.claude/hooks/scope_guard.py` → out-of-tree file writes,
   `DANGEROUS_BASH` patterns, and Bash redirects to absolute paths outside the
   tree.

**Rationale**: `settings.json` is *project* settings. Claude Code applies it to
**every** session opened in the repository, the operator's own interactive
session included. That is why the operator is blocked today (spec Context).
A static settings file cannot tell sessions apart, so FR-011 cannot be met
while the deny list lives there. The hook runs per tool call, sees the
session's environment, and can decide per origin and per profile.

**Consequence**: The shipped `settings.json` loses its `deny` array. The hook
takes over those six rules under `strict`, with the same allow/deny decision
for every input. The hook matcher widens from
`Write|Edit|MultiEdit|NotebookEdit|Bash` to also cover `WebFetch|WebSearch`.

**Alternatives considered**:
- Keep `settings.json` deny and add a second, human-only settings file
  (`settings.local.json`). Rejected. The local file is per-checkout and
  uncommitted, so it does not travel into worktrees, and deny rules from any
  settings source still win over allow rules — the local file could not
  re-allow anything.
- Ship two committed packs (strict and permissive) and swap files at run
  start. Rejected. FR-013 requires one committed pack. Swapping files in a
  worktree would also show as an uncommitted change and pollute the feature
  commit.

---

## R2 — How orchestrator sessions are actually launched

**Decision**: Rely on the real SDK path, not the adapter's command template.

**Findings** (from source):
- `Jido.Claude.Adapter.run/2` builds `ClaudeAgentSDK.Options` from the
  `RunRequest` and calls `sdk_module().query/2`. `Options.to_args/1` emits
  `--permission-mode <mode>`, `--allowedTools`, `--disallowedTools`. It does
  **not** emit `--dangerously-skip-permissions`.
- `--dangerously-skip-permissions` appears only in
  `runtime_contract/0`'s `triage_command_template` / `coding_command_template`
  (the sprite/shell executor path), which this orchestrator does not use.
- So headless phases run under `--permission-mode acceptEdits` or `plan`
  today. A tool that is not pre-approved in `allowed_tools` has no one to
  approve it headless and is refused. Today that alone blocks `WebFetch` /
  `WebSearch` for every phase, independent of the pack.

**Consequence**: Under `permissive`, the pack relaxation is not enough.
`PhaseRequest` must also stop narrowing (FR-005, FR-007):
`permission_mode: :bypass_permissions` and an `allowed_tools` set that adds
`WebFetch` and `WebSearch`. `:bypass_permissions` is also what lets a write
outside `cwd` through — `acceptEdits` only auto-approves edits inside the
working directories.

`docs/enforcement.md` and `docs/harness-contract.md` both say the adapter runs
with `--dangerously-skip-permissions`. That is stale for the SDK path. The
doc update (FR-017) corrects it.

**Verify at implementation**: that project `settings.json` deny rules would
still apply under `bypassPermissions`. This no longer matters for correctness
once R1 moves the deny list into the hook, but the enforcement guide should
state the observed behaviour.

---

## R3 — Telling orchestrator sessions from human sessions (FR-011, FR-012)

**Decision**: The hook reads its process environment (inherited from the
`claude` process that runs it) and decides origin in this order:

1. `SPECKIT_ORCHESTRATED=1` is set → **orchestrated**. The profile is
   `SPECKIT_CONTAINMENT_PROFILE`. Any value other than `strict` or
   `permissive` (including unset) → `strict`.
2. Else `CLAUDE_CODE_ENTRYPOINT` is in the human allowlist (`{"cli"}`) →
   **interactive**. The pack adds no denial.
3. Else → **undecided** → `strict`.

The orchestrator sets both `SPECKIT_*` variables on every headless session it
starts, through `RunRequest.metadata["claude"][:env]`. The adapter's
`build_options/2` merges `metadata["claude"]` keys found in `@option_keys`,
and `:env` is one of them. `ClaudeAgentSDK.Process.build_env_vars/1` layers
that map over the BEAM's own environment for the subprocess.

**Rationale**:
- The marker is **positive** for the orchestrator. The SDK's own
  `CLAUDE_CODE_ENTRYPOINT` is set with `Map.put_new(…, "sdk-elixir")`. If the
  operator starts `iex -S mix` from inside a Claude Code shell, the BEAM
  inherits `CLAUDE_CODE_ENTRYPOINT=cli` and `put_new` keeps it. So
  entrypoint alone would mark a headless phase as human. The explicit
  `SPECKIT_ORCHESTRATED` marker closes that hole, and rule 1 is checked
  before rule 2.
- Human detection is **positive** too. A session is only treated as human on
  a known interactive entrypoint (observed `CLAUDE_CODE_ENTRYPOINT=cli` in an
  interactive Claude Code 2.1.284 session). An unknown or missing entrypoint
  falls to `strict`. That is FR-012's "fail toward strict".
- A leaked `SPECKIT_ORCHESTRATED` in a human shell makes that human session
  strict. That is the safe direction.
- A subprocess `claude` started by a phase's Bash inherits the markers and
  stays under the run's profile.

**Verify at implementation**: the entrypoint value for other human surfaces
(IDE extensions, desktop app, a human's own `claude -p`). Ship only `cli`.
Any other surface is strict until observed and added — documented in the
runbook as a known limitation, not a bug.

**Alternatives considered**:
- Use the hook input's `permission_mode` (`bypassPermissions` ⇒
  orchestrated). Rejected. Orchestrator sessions run `acceptEdits`/`plan`
  under `strict` (R2), which a human also uses.
- A lock file in the worktree written by the orchestrator. Rejected. It is
  visible to the human session opened in the same kept worktree (spec edge
  case: "still treated as a human session"), and it is a file the model can
  delete.

---

## R4 — Hook rules per origin and profile

**Decision**: One pure decision function in the hook,
`decide(origin, profile, tool, tool_input, root) -> None | (rule_id, detail)`.

| Origin | Profile | Well-formed input | Malformed input |
|---|---|---|---|
| orchestrated | `strict` | today's union of settings + hook rules | deny |
| orchestrated | `permissive` | allow everything (FR-006: no floor) | deny |
| interactive | — | allow everything | deny |
| undecided | (`strict`) | today's union | deny |

"Malformed" keeps today's meaning: stdin that is not JSON. FR-010 applies
under every origin, so an interactive session with unparseable hook input is
also denied — a guard that cannot read its input must not wave writes
through.

**Strict rule set** (the union, decision-identical to today for every input
the red-team suite covers):

| rule_id | Source today | Match |
|---|---|---|
| `write_outside_worktree` | hook | file tool target outside `cwd` |
| `bash_rm_rf_root` | hook | `\brm\s+-rf\s+/(?:\s\|$)` |
| `bash_rm_rf_home` | hook | `\brm\s+-rf\s+~` |
| `bash_sudo` | hook + settings | `\bsudo\b` |
| `bash_git_push` | hook + settings | `\bgit\s+push\b` |
| `bash_curl` | settings (`Bash(curl:*)`) | command starts with `curl` (covers `curl … \| sh`) |
| `bash_wget` | settings (`Bash(wget:*)`) | command starts with `wget` (covers `wget … \| sh`) |
| `bash_pipe_to_shell` | hook | `(curl\|wget)\b[^\|]*\|\s*(sh\|bash)` anywhere |
| `bash_fork_bomb` | hook | today's regex |
| `bash_chmod_777_root` | hook | `\bchmod\s+-R\s+777\s+/` |
| `bash_redirect_outside_worktree` | hook | `>>?` to an absolute path outside `cwd` |
| `tool_web_fetch` | settings | tool `WebFetch` |
| `tool_web_search` | settings | tool `WebSearch` |

The settings prefix rules are replicated as prefix matches after leading
whitespace, which is what Claude Code's `Bash(cmd:*)` prefix rule means. The
hook's existing regexes stay as they are. The union can only deny more than
the hook alone, never less, so no input that is denied today becomes allowed
under `strict`.

**Denial text (FR-016)**:
`scope_guard[<profile>|<origin>]: <rule_id>: <detail>`, for example
`scope_guard[strict|orchestrated]: write_outside_worktree: write outside worktree denied: /etc/passwd`.
Every existing `detail` string is kept verbatim, so the red-team suite's
substring assertions (`"outside worktree"`, `"redirect outside worktree"`,
`"unparseable"`) keep matching.

**Pack contract marker**: the hook carries `PACK_CONTRACT = 2` and prints it
for `scope_guard.py --contract`. Preflight reads that (R7).

---

## R5 — Per-phase permissions under each profile (FR-005, FR-007, FR-008)

**Decision**: `PhaseRequest` gains a `:containment` option (`"strict"` |
`"permissive"`, default `"strict"`) on `build/3` and `build_remediation/3`.

- `"strict"` → `permissions/1` exactly as today (the `analyze`/`describe`
  `:plan` read-only sets, `clarify`'s no-Bash set, the write+Bash set for the
  rest, `build_remediation`'s set). The built `RunRequest` is identical to
  today except for the `metadata` env markers (R3).
- `"permissive"` → one set for every phase and every remediation:
  `permission_mode: :bypass_permissions`,
  `allowed_tools: ~w(Read Write Edit MultiEdit NotebookEdit Bash Grep Glob WebFetch WebSearch)`,
  `disallowed_tools: ~w(Agent Task ScheduleWakeup)` (FR-008, unchanged).

The `metadata` env markers are set under **both** profiles. Under `strict`
that is the only `RunRequest` difference from today. It does not change a
session's behaviour, because the hook's orchestrated-strict branch is the
same rule set an unmarked session got before.

**Rationale**: one function owns the profile → permission mapping, so every
session-driving site (`RunFeaturePhase` incl. implement chunks,
`RunAutoRemediation`, `RunRemediation`, `Describe`) gets it by passing one
option. No site builds permissions itself.

**Alternatives considered**: keep `:accept_edits` under permissive and only
add tools. Rejected — writes outside `cwd` would still be refused headless
(R2), which violates FR-005.

---

## R6 — Where the profile is recorded and how it flows (FR-003, FR-004)

**Decision**: Add a thirteenth `RunContext` key, `containment_profile`,
stored as a string (`"strict"` | `"permissive"`), never an atom from file
content (repo-wide `String.to_atom/1` ban, 017 R4).

- `Config.containment_profile/0` — the global default. Default `:strict`.
  Raises on any other value at read time (fail loud).
- `RunContext.capture/1` — `opts[:containment_profile]` over
  `Config.containment_profile/0`.
- `RunContext.from_map/1` — a **missing** key decodes to `"strict"`, not
  `nil`. Every pre-030 run record and checkpoint was strict by construction,
  and a `nil` would make `merge/2` fall back to the *live* config default —
  which could by then be `permissive` (FR-004, SC-005).
- The value reaches sessions the same way `layout` does: `FeatureRunner`
  reads it from `run_context`, passes it to `InitFeature`, which stores
  `containment` in `FeatureAgent` state; each action passes
  `containment: state.containment` to `PhaseRequest`. `Describe.run/4` takes
  it as an option from `FeatureRunner`.
- Persisted through the existing paths: `RunSettings.settings` (free-form
  map, no migration) and the checkpoint's `RunContext.to_map/1`.

**Resume / continue lock (FR-004, edge case)**: `resume/2`,
`continue_run/1`, `resume_run/1` and the publish-only route take the profile
from the recorded run. An explicit `:containment_profile` opt that differs
from the recorded one is refused with
`{:error, {:preflight, [{:containment_profile_locked, recorded}]}}` before any
side effect. It is not silently ignored (Principle II). The same value is
accepted as a no-op.

**Validation**: `run/1` preflight rejects an unknown value with
`{:error, {:preflight, [{:invalid_containment_profile, value}]}}`. It is
checked next to `preflight_remediation/1` and before any store write.

**Not live-editable**: `LiveConfig` does not accept the key. The profile is
fixed when the run starts (Key Entities).

---

## R7 — Pack install and preflight (FR-013)

**Decision**:
- `TargetPack.install/2` writes the new `settings.json` (no `deny`, matcher
  widened) and the new hook. Unchanged otherwise.
- `TargetPack.verify/2` gains `profile:` (`"strict"` default). For
  `"permissive"` it adds one check, `check_pack_contract/2`: read the
  **committed** hook with `git -C repo show HEAD:.claude/hooks/scope_guard.py`
  and require `PACK_CONTRACT = 2`. It also requires the committed
  `settings.json` to carry no `permissions.deny` entry. A failure is
  `{:pack_outdated, ".claude/hooks/scope_guard.py", "re-run TargetPack.install/2 and commit"}`.
- Under `"strict"`, `verify/2` is unchanged. An old pack still enforces
  today's rules (its settings deny + old hook), so a strict run against an
  un-upgraded target behaves byte-identically and does not fail preflight.

**Rationale**: the worktree is created from committed state, so the working
tree copy is not what a session will run under. Reading `HEAD:` is what
`check_committed/3` already does for the constitution, and it catches an
installed-but-uncommitted upgrade.

**Human sessions against an old pack** stay blocked until the operator
upgrades the pack. That is documented in the runbook, not enforced — there
is no run to preflight.

---

## R8 — Operator surfaces (FR-015, Principle VII)

**Decision**: every surface adds a marker **only** when the profile is
`permissive`; under `strict` each rendering function returns what it returns
today.

| Surface | Change under `permissive` | Under `strict` |
|---|---|---|
| `Coordinator` final report | `containment_profile: "permissive"` key | key absent |
| `Coordinator.status/0` snapshot | same key | key absent |
| `Report.format_status/1` | line `containment: permissive (no pack deny list)` | line omitted (`nil`, like `advanced_line/1`) |
| Topbar (every view, incl. Mission Control) | neutral chip `containment: permissive` | no chip |
| Run Detail | `CONTAINMENT` block with `containment_profile: permissive` | SETTINGS chips skip `containment_profile` when `strict` |
| Configuration page | row "containment default: permissive" and live run's profile | no row when default is `strict` and no permissive run is live |
| PR body | `Containment.pr_note("permissive")` appended after `Remediation.pr_note/1` | `pr_note("strict") == ""` |

**No new colour.** The marker is not a status, and the design constitution
reserves saturated colours for status (§II). The chip uses the existing
neutral chip tokens (`--raised`, `--border-strong`, `--text`, `--r-chip`)
with mono text, so `design_contract_test` stays green with no amendment to
`docs/design-constitution.md`.

**Trigger Run page** gains the profile control itself (FR-003). That is an
input, not a record of a run, so it is the one surface that changes for
every operator. It defaults to the configured global default, which ships
as `strict`.

---

## R9 — FR-016 scope: which denials can name the profile

**Decision**: FR-016 is met by every denial the **pack** emits (R4). Denials
issued by the CLI itself from `allowed_tools` / `disallowed_tools` /
`permission_mode` carry the CLI's own text, which the orchestrator does not
author.

- Under `strict` those CLI denials are unchanged from today, as FR-002
  requires. Rewriting them would need a transcript prefix, which would change
  a strict operator surface.
- Under `permissive` the only remaining CLI-level restriction is FR-008's
  tool exclusion. Those tools are hidden from the session, not denied per
  call, so no per-call denial text exists.
- The run's profile is always on the run record (R6). A reader of any
  transcript can resolve which profile applied.

**Flag for `/speckit-analyze`**: this reads FR-016 as scoped to pack
denials. If the spec intends CLI denials too, FR-002 and FR-016 conflict
under `strict`.

---

## R10 — Session pushes vs. the orchestrator's publish (edge cases)

**Decision**: no publish change.

`Worktree.push/2` reads `refs/remotes/<remote>/<branch>` before it fetches.
A session `git push` from the worktree updates that same ref, because
worktrees share the base repo's refs. So after a session push to the
orchestrator's branch, `known == after-fetch`, and publish takes the
`--force-with-lease=<branch>:<sha>` path. The publish replaces the session's
push with the squashed feature commit. It does not fail only because the
branch already exists.

A remote change the orchestrator cannot see locally (for example a push via
`gh api`) makes publish refuse with `{:remote_branch_moved, …}`. That is
today's rule for someone else's push, and it stays: the orchestrator never
overwrites a remote state it did not observe.

A push to any other branch is not a publish (the publisher only ever pushes
`Worktree.branch_name/1`). The branch-drift gate still reads only the
checked-out branch at session end (`BranchGuard.check/2`), unchanged.

---

## R11 — Constitution amendment (FR-014)

**Decision**: amend Principle III to **6.0.0 (MAJOR)** before implementation
merges, through `/speckit-constitution`, as its own commit on this branch.

Principle III today is unconditional: the hook "MUST deny out-of-tree writes
and dangerous Bash" and per-phase permissions "MUST further narrow tools".
Making both conditional on a per-run opt-in is a redefinition of a principle
guarantee — the same class as the 3.0.0, 4.0.0 and 5.0.0 amendments.

The amendment text must:
- keep `strict` as the default, and keep today's MUSTs verbatim for it;
- define `permissive` as an explicit per-run opt-in that removes the pack
  deny list and per-phase narrowing, with **no floor** (Clarifications Q1);
- keep fail-closed on malformed hook input under every profile and origin;
- require the orchestrator to mark its own sessions, and require the pack to
  resolve an unmarked, non-interactive session to `strict`;
- require the profile to be visible on every operator surface and PR
  (Principle VII);
- recommend the container recipe for `permissive` runs;
- keep the correctness gates, breaker and deadlines out of scope of the
  profile (FR-009).

**Alternatives considered**: MINOR bump as an "added exception". Rejected —
the exception removes a MUST for a whole class of runs.
