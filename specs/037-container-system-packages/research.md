# Research: Container System Packages

**Feature**: 037-container-system-packages | **Date**: 2026-10-08

No `NEEDS CLARIFICATION` remained in the Technical Context after the spec's
Clarifications session. The items below are the design decisions the plan
depends on. Each one records what was chosen, why, and what was rejected.

## R1 — Where the declared packages are installed

**Decision**: One new `RUN` block at the **end of the `base` stage**, after the
Android block, driven by a new build arg `EXTRA_APT_PACKAGES` (default empty):

```text
if [ -n "$EXTRA_APT_PACKAGES" ]; then
  apt-get update && apt-get install -y --no-install-recommends $EXTRA_APT_PACKAGES
  && printf '%s\n' $EXTRA_APT_PACKAGES > /etc/autonomous/apt-packages
  && rm -rf /var/lib/apt/lists/*
fi
```

`dev` (via `toolchain`) and `release` both build `FROM base`, so this single
block covers both images (FR-001). Putting it last keeps every earlier `base`
layer cached when only the list changes. The manifest
`/etc/autonomous/apt-packages` is written only when the list is non-empty. It
is what the `sysdeps` smoke check reads.

**Rationale**: The existing `WITH_WEB`/`WITH_DESKTOP`/`WITH_ANDROID` blocks
follow the same pattern: a no-op when the arg is unset. An empty list adds an
empty layer and no files, so image *content* is unchanged (FR-002, SC-004). An
unknown name makes `apt-get` exit non-zero with
`E: Unable to locate package <name>`, so the `compose build` fails before
tagging (FR-003).

**Alternatives rejected**:
- A `LABEL` that records the list. It is always present, so the image config
  would change even with no packages (it breaks FR-002).
- Separate blocks in `dev` and `release`. That duplicates the logic and lets
  the two drift apart.
- A per-target package file. The Clarifications rule this out: one shared
  image.

## R2 — Build-script option grammar and validation (FR-004)

**Decision**: `scripts/autonomous build --apt "<names>"`. The option is
repeatable and its values accumulate. Names are separated by whitespace or
commas. Each token must match
`^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+)?$` (a Debian package
name, an optional `:arch`, and an optional `=version`). The first token that
does not match exits **2** with `invalid package name '<token>'`, before any
`docker` call. Valid tokens are joined with single spaces and exported as
`EXTRA_APT_PACKAGES`. `--apt` is valid only with `build`.

**Rationale**: Validating in the wrapper keeps shell metacharacters out of the
Dockerfile's word-split `$EXTRA_APT_PACKAGES`, so it can never become a command
(edge case "shell metacharacters"). Exit 2 is already the wrapper's usage code.

**Alternatives rejected**:
- Passing the raw string and quoting inside the Dockerfile. `apt-get` still
  receives arbitrary tokens, and an `-o`-style option could slip in.
- JSON or array build args. Compose has no list build args.

## R3 — Agent-root image option and sudoers grant (FR-005/FR-006)

**Decision**: Build arg `WITH_AGENT_ROOT` (0/1; wrapper flag `--agent-root`).
When it is 1, the last `base` block (after R1's block) does three things:

1. It installs `sudo`.
2. It writes `/etc/sudoers.d/autonomous-agent-root` (mode `0440`, checked
   with `visudo -cf`):
   ```text
   Defaults env_keep += "DEBIAN_FRONTEND"
   ALL ALL=(root) NOPASSWD: ALL
   ```
3. It writes `/etc/apt/apt.conf.d/99autonomous-no-remove` with
   `APT::Get::Remove "false";`.

When it is 0, nothing is installed, and `sudo` stays absent as it is today
(FR-006).

**Rationale**:
- The grant names **no user**, so it applies to whatever uid the container runs
  as, as long as that uid has a passwd entry. The wrapper always builds with
  `UID=$(id -u)` and runs with `user: ${AUTONOMOUS_UID}`, so the two match, and
  the grant also works when `useradd` reused an existing gid. If a uid has no
  passwd entry, sudo cannot run at all. The start-time check (R4) catches
  that, and the capability is then not advertised (edge case "elevation fails
  at start").
- sudoers is **not** narrowed to apt. Narrowing it would not be a real
  boundary, because `apt-get` itself can run arbitrary commands through
  `-o APT::Update::Pre-Invoke=…` and maintainer scripts. The real boundaries
  are the hook's grammar (R5), which is a per-command policy, and the
  container, which is the outer boundary. The spec's enforcement-doc
  requirement (FR-015) says this explicitly. A full grant also lets the smoke
  check and the start probe use `sudo -n true`.
- `APT::Get::Remove "false"` makes `apt-get`/`apt` refuse any install that
  would remove a package. This is defense in depth for the edge case "removes
  or purges a package": an `install` that conflicts with something already
  present is otherwise a removal by another name.
- `env_keep DEBIAN_FRONTEND` keeps `noninteractive` (already image `ENV`)
  across sudo's env reset, so package installs never block on a debconf prompt
  in a headless session.

**Alternatives rejected**:
- `autonomous ALL=…` keyed on the user name. It breaks when the gid was reused
  and the user name differs.
- Making `/etc/passwd` writable, or `nss_wrapper`. sudo is setuid and ignores
  `LD_PRELOAD`, and a writable passwd is worse than the problem it solves.
- A setuid helper limited to apt. That is new privileged code to maintain, and
  it has the same `-o` escape.

## R4 — Start-time verification and advertisement (FR-007)

**Decision**: A new entrypoint step, `agent_root`, runs after
`trust_workspaces` and before any VM. It first runs
`unset AUTONOMOUS_AGENT_ROOT` (a value from `.env` or compose is never
trusted). Then:

```text
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    export AUTONOMOUS_AGENT_ROOT=1; say "agent root: available (sudo apt-get)"
  else
    warn "agent root built in but 'sudo -n true' failed for uid $(id -u); not advertised"
  fi
fi
```

Without `sudo` (the default image), the step prints nothing, so container
start output stays byte-identical. A smoke subcommand `agent-root` runs only
this step and prints `AUTONOMOUS_AGENT_ROOT=<0|1>`. It works like the
`trust-config` hook.

**Rationale**: The capability is advertised only after a positive check.
`no-new-privileges`, a uid with no passwd entry, or a broken sudoers file all
fail the probe, so the system fails toward "not advertised". Exporting before
`exec` puts the value in the VM's environment, which every session the VM
starts inherits.

**Alternative rejected**: Advertising from the build arg alone. That is not a
positive verification and lies when the runtime blocks elevation.

## R5 — The `strict` exception grammar in `scope_guard.py` (FR-008/FR-009/FR-010)

**Decision**: The hook gains `agent_root_active(env)`, which is true iff
`AUTONOMOUS_CONTAINER == "1"` and `AUTONOMOUS_AGENT_ROOT == "1"`. In
`check_bash`, the `bash_sudo` rule (and only that rule) is evaluated through
`sudo_allowed(cmd)` when `agent_root_active`. Every other rule (rm -rf, push,
curl, wget, pipe-to-shell, fork bomb, chmod, the redirect check) still runs
against the whole command as today (FR-014). Without both markers, the code
path is today's, byte for byte (FR-010).

`sudo_allowed(cmd)` is true only when all of the following hold:

1. The command contains no command substitution, process substitution, or
   subshell: none of `` ` ``, `$(`, `<(`, `>(`, and no `(`/`)` tokens.
2. `shlex.shlex(cmd, posix=True, punctuation_chars=True)` tokenizes it without
   error. An unbalanced quote means deny.
3. Every `sudo` token begins a segment. Segments are split on `&&`, `||`, `;`,
   `|`, `&`, and newline. A `sudo` anywhere else (an argument, a quoted
   string) means deny, as today.
4. Each segment that starts with `sudo` has this exact shape:
   `sudo [-n] [DEBIAN_FRONTEND=noninteractive] <pm> <action…>`, where:
   - `apt-get` or `apt` takes the action `update`, or `install` followed only by
     the option allowlist {`-y`, `--yes`, `--assume-yes`, `-q`, `-qq`,
     `--quiet`, `--no-install-recommends`} and ≥1 package token matching R2's
     regex. A token that starts with `-` and is not on the list (notably
     `-o`, `-c`, `--option`, `--config-file`, `-f`, `--fix-broken`,
     `--reinstall`, `--allow-*`), and any token containing `/` (a local
     `.deb` or a path), means deny;
   - `apt` also takes `list`, `show`, or `policy` (queries);
   - `dpkg` takes only query flags {`-l`, `--list`, `-s`, `--status`, `-L`,
     `--listfiles`, `-S`, `--search`, `--get-selections`}, followed by
     package-name or pattern tokens without `/`.

   Everything else is denied: `remove`, `purge`, `autoremove`, `upgrade`,
   `dist-upgrade`, `full-upgrade`, `-i`/`--install`, `--configure`, `-E`,
   `-u`, `-s`, `sh -c`, and any other program.

On deny with agent root active, the reason keeps rule id `bash_sudo` and
gives an extended detail:
`sudo (agent root allows only apt-get/apt update|install and dpkg queries)`.
Without agent root, the detail stays `sudo` as today.

**Rationale**:
- Install-only plus queries is the Clarifications answer. `-o` and local
  `.deb` paths are the two documented ways to make apt or dpkg execute
  arbitrary code (FR-009).
- Splitting the command into segments handles the "chained" edge case:
  `sudo apt-get update && sudo apt-get install -y x` is allowed, and
  `sudo apt-get install -y x; sudo rm …` is denied.
- Rejecting substitutions closes `sudo apt-get install $(…)` and
  `` sudo apt-get install `…` ``.
- `shlex` is stdlib, so the hook gains no dependency. The hook still fails
  closed on unparseable input.
- One rule id keeps every existing log, test, and doc reference to `bash_sudo`
  valid.

**Alternatives rejected**:
- A regex-only allow pattern. It is too easy to bypass with quoting or
  chaining.
- Allowing any apt action except remove/purge. Upgrades can replace the
  toolchain the orchestrator runs on, and the Clarifications chose
  install-only.
- Rewriting the command through `updatedInput` (for example injecting
  `--no-remove`). It mutates model input silently. The apt.conf drop-in (R3)
  gets the same effect without doing that.

## R6 — Pack contract 5 and preflight (FR-012)

**Decision**:
- `PACK_CONTRACT = 5` in the hook. `TargetPack` installs contract 5.
- `TargetPack` replaces string equality with integer thresholds:
  `@permissive_min_contract 4` (unchanged meaning: contract 4 or later and no
  `permissions.deny`) and `@agent_root_min_contract 5`.
- `check_pack_contract/1` keeps its result shape for permissive.
- A new function, `TargetPack.agent_root_warning(repo)`, returns `:ok` or
  `{:warning, {:pack_below_agent_root_contract, found :: integer | :unknown, 5}}`.
  It reads the **committed** hook (`git show HEAD:`), exactly as the
  permissive check does.

Preflight (`run/1` → `preflight_stacked/2` and `spec_run_opts/3`) calls it
only when `AgentRoot.advertised?()` is true and the run's profile is
`"strict"`. A warning is logged with `Logger.warning` and is **not** a problem
entry, so the run starts (Clarifications). Without agent root, nothing is
checked (FR-012 "accepted silently").

**Rationale**:
- With equality kept, a contract-5 pack would fail the permissive check and a
  contract-4 pack would fail the next bump. Thresholds make "newer is fine"
  explicit.
- Permissive behaviour does not change: contract 4 still passes, and so does
  contract 5 (FR-011).

**Alternative rejected**: Failing preflight. The Clarifications chose warn and
start. The older pack fails closed (it keeps denying sudo), so this is safe.

## R7 — How sessions learn about agent root (FR-007/FR-013)

**Decision**: A new module, `Autonomous.AgentRoot`.
`advertised?(env \\ System.get_env())` is the only env read and the boundary
function. Everything else in the module is pure:

- `session_env(true)` returns
  `%{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_AGENT_ROOT" => "1"}`;
  `session_env(false)` returns `%{}`.
- `prompt_note(true)` returns the agent-root block from
  `priv/prompts/agent_root.md`; `prompt_note(false)` returns `""`.

`PhaseRequest` gains an `:agent_root` option (a boolean whose default is
`AgentRoot.advertised?()`):
- `session_metadata/2` merges `AgentRoot.session_env/1` under the existing
  containment markers and timeouts.
- `build/3` appends `AgentRoot.prompt_note/1` to the `:implement` prompt (every
  scope) and to the `:converge` prompt. It goes after the headless rule and
  before the resume, clarify-answers, and background-retry blocks, so those
  stay last.

With `false`, the request is byte-identical to today (FR-013, SC-004).

**Rationale**:
- Passing the markers explicitly on the launch env does not rely on the SDK
  transport inheriting the VM's environment, and it makes the markers visible
  in `RunRequest` tests. The same channel already carries
  `AUTONOMOUS_ORCHESTRATED`.
- Defaulting the option from the env keeps every existing caller unchanged,
  while tests pass `agent_root: true|false` explicitly.
- The note applies under both profiles. Telling a permissive session that it
  may use `sudo apt-get` changes no pack behaviour (FR-011), and leaving the
  note out would make a permissive session report "tests not run" for the
  same reason the incident did.

**Alternative rejected**: Reading the env inside `PhaseRequest`. That puts a
second hidden env read in a prompt builder.

## R8 — The install log line (FR-018)

**Decision**: A pure function, `AgentRoot.installs(result :: PhaseResult.t())`,
returns `[%{command: String.t(), packages: [String.t()]}]`. For each Bash
`:tool_call` in `tool_events` it collects every segment of the form
`sudo … (apt-get|apt) install <args>`, using the same token rules as R5 (the
package tokens are the non-option arguments). Calls whose paired
`:tool_result` carries a `scope_guard[` denial reason are skipped. The
session-driving sites already run per-session post-processing for the
branch-drift and untrusted-workspace gates: `RunFeaturePhase`,
`ChunkRunner` (implement chunks), `RunRemediation`, and `RunAutoRemediation`.
After each session, each site calls
`AgentRoot.log_installs(feature, phase, result)`, which emits one
`Logger.info` line per allowed install:

```text
agent root: feature 003 (implement) installed system packages: libasound2-dev pkg-config — add them to `scripts/autonomous build --apt` to persist
```

Nothing is written to the store.

**Rationale**:
- The hook runs inside the CLI and cannot reach the orchestrator's log.
- The orchestrator already folds every tool call into `PhaseResult`, so the
  log line needs no new channel.
- The line names the feature and the packages (FR-018). Skipping denied calls
  keeps the log honest. The hook is still the authority on allow and deny; the
  log only mirrors what was allowed.

**Alternatives rejected**:
- The hook appending to a shared log file. That needs a new cross-process
  file contract and a tailer.
- Persisting the installs on the run record. The Clarifications rule this
  out.

## R9 — Operator surface for the preflight warning (FR-012)

**Decision**: There are two surfaces, and neither is persisted:

1. The `Logger.warning` at preflight (R6).
2. The console **Configuration** page (`ConfigLive`) gains an "Agent root" row
   computed live by a pure view function from `AgentRoot.advertised?()` and
   `TargetPack.agent_root_warning(Config.repo())`:
   - `not advertised` (default) renders nothing new, so the page is
     byte-identical;
   - `available` renders one row, "Agent root: available (strict allows
     `sudo apt-get`/`apt` install)";
   - `pack below contract 5` renders the same row plus a warning line,
     "committed pack is contract N; re-run `TargetPack.install/2` and commit
     for the exception to apply".

The page uses existing tokens and classes only (design guard G-* rules) and no
`inspect/1`.

**Rationale**:
- Principle VII: a relaxation must be visible where the operator looks.
- The Clarifications ruled out a run annotation, so the capability lives on
  the instance-level Configuration page, not in Run Detail or the PR body.

**Alternative rejected**: A topbar badge. It adds a status color, needs a
design-constitution change, and the spec does not require it.

## R10 — Smoke check `sysdeps` (FR-016)

**Decision**: `scripts/container-smoke.sh sysdeps` runs as
`--user $(id -u):$(id -g)` against `${SMOKE_IMAGE:-autonomous-dev:local}`
(so the release image is checked the same way):

1. It reads `/etc/autonomous/apt-packages` if present and checks
   `dpkg -s <pkg>` for each entry. With no manifest it reports SKIP for that
   part.
2. If `sudo` exists, it checks the following, and otherwise SKIPs them:
   - `sudo -n true`;
   - the entrypoint's `agent-root` subcommand prints
     `AUTONOMOUS_AGENT_ROOT=1`;
   - `sudo -n apt-get update && sudo -n apt-get install -y --no-install-recommends <probe>`
     succeeds (the probe defaults to `pkg-config`, overridable through
     `SMOKE_SYSDEPS_PROBE`);
   - `sudo -n apt-get remove -y <probe>` is refused by the no-remove
     config (`APT::Get::Remove "false"` makes apt abort).
3. If `sudo` is absent, it checks that `command -v sudo` fails and that
   `agent-root` prints `AUTONOMOUS_AGENT_ROOT=0`.

`all` includes `sysdeps`.

The hook's decisions are **not** smoke-tested here. They are covered
hermetically by `scope_guard_test` across the full matrix (SC-003).

## R11 — Constitution amendment (FR-017)

**Decision**: MINOR, 6.0.2 → **6.1.0**. Principle III's `strict` bullets gain
one bullet:

> the hook MAY allow a privileged command only when both the in-container
> marker and the verified agent-root marker are present, and only when every
> privileged part refreshes the system package index, installs packages, or
> queries the package database. Removal, upgrade, local package files, options
> that execute commands, and every other privileged command stay denied. This
> exception relies on the container as the outer boundary.

The Sync Impact Report is prepended. The amendment is the first
implementation task, so the code lands against a constitution that already
permits it (Complexity Tracking records the transient deviation).

**Rationale**: It narrows an existing MUST under an explicit, verified
condition. That is a materially expanded section, not a new principle and not
a backward-incompatible redefinition, because without both markers `strict`
is unchanged.

## R12 — Test-environment hygiene

**Decision**:
- `scope_guard_test`'s `@env_clear` gains `AUTONOMOUS_CONTAINER` and
  `AUTONOMOUS_AGENT_ROOT`. The suite runs **inside** the dev image
  (`scripts/autonomous test`), where `AUTONOMOUS_CONTAINER=1` is image `ENV`,
  so without clearing them the matrix would depend on the shell.
- `AgentRoot.advertised?/1` takes the env as an argument in tests.
- `PhaseRequest` tests pass `agent_root:` explicitly. The default-suite
  assertions that "strict request is byte-identical" pin `agent_root: false`.

**Rationale**: Quality & Test Discipline requires that the real hook be
red-teamed under a pinned environment.
