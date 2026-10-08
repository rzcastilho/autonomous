# Implementation Plan: Container Workspace Trust

**Branch**: `036-container-workspace-trust` | **Date**: 2026-10-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/036-container-workspace-trust/spec.md`

## Summary

Containerized sessions ignore the target pack's `permissions.allow` entries
because the container-private `~/.claude.json` has no trust record for the
target. Two changes:

1. **Container trust step** (US1–US3). After the identity is derived and any
   `--with-login` seed is copied, before any CLI or VM process exists, the
   entrypoint merges `projects[<path>].hasTrustDialogAccepted: true` for exactly
   the target repo and the instance worktree root into `$HOME/.claude.json`.
   It preserves every other key, writes atomically (`0600`), skips the write
   when nothing changed, and refuses to touch an unparsable file. Research R1
   found that the CLI resolves a `git worktree`'s trust key to its **main
   repository**. The repo record is therefore the one that makes every
   orchestrated session trusted. The worktree-root record is kept: the spec
   requires it, it is bounded, and it still works if a later CLI keys
   worktrees by their own path.
2. **Untrusted-workspace gate** (FR-013, container and host). A per-session SDK
   `stderr` callback picks out the CLI's `… this workspace has not been
   trusted` lines. A pure parser turns them into an observation. Under
   `strict` the observation becomes a gate signal, and `Pipeline.next/3` fails
   the phase with `{:untrusted_workspace, phase, obs}`. This happens after the
   branch-drift and session-death checks, the failure is never retried, and
   the report and console render it. Under `permissive` the site logs a
   warning and the phase continues.

Plus the US4 finding: on host 2.1.294, project hooks **run** in an untrusted
workspace (research R3). It is recorded in `docs/container.md`, along with a
smoke procedure that confirms `PreToolUse`/`scope_guard` on the pinned
2.1.286.

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28.5.0.6 (mise-pinned); POSIX `sh` + inline `python3` (stdlib) in the container entrypoint

**Primary Dependencies**: `jido_harness` / `jido_claude` (pinned SHAs; `metadata["claude"]` → SDK `Options`), `claude_agent_sdk` (`Options.stderr` line callback), Claude Code CLI 2.1.286 in the image

**Storage**: No store schema change. External file: container-private `$HOME/.claude.json` (CLI-owned JSON)

**Testing**: ExUnit (default hermetic suite). The entrypoint step is tested by running the real script (`trust-config` subcommand) against temp `HOME`s, in the same style as `scope_guard_test`. Container and agent checks go in `scripts/container-smoke.sh trust` / `us-trust-hook`, run by hand

**Target Platform**: Debian bookworm container (dev + release shapes); macOS/Linux host for the gate

**Project Type**: OTP application + container runtime scripts

**Performance Goals**: Trust step adds < 200 ms to container start. Stderr capture adds no per-event work to the stream fold (lines arrive on a side channel)

**Constraints**: Never write the host's `~/.claude.json`. Never write the container config in place. No concurrent writer: the step runs before any CLI process. `warnings_as_errors`. Gate outcome byte-identical when no untrusted line is seen

**Scale/Scope**: 1 entrypoint step + 1 subcommand. 1 new pure module (`WorkspaceTrust`), 1 small collector process, 6 session-driving sites, 1 `Pipeline` clause, 1 `PhaseStep` clause, 2 renderers, 1 env line, docs (container, runbook, CLAUDE.md), smoke section

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment | Status |
|---|---|---|
| I. Pure core, isolated contracts | The CLI's message wording lives only in `WorkspaceTrust` (pure, fixture-tested with real captured lines). `Pipeline.next/3` gets a signal extracted upstream and never reads the profile or stderr. The plan does not predict trust from `~/.claude.json` (that would encode a guess about the CLI's resolution rules); the CLI's own report is used instead | PASS |
| II. Fail loud at boundaries | An unparsable container config stops startup, names the file and leaves it unmodified. A strict untrusted session fails loudly instead of running with a partly applied pack. The parser treats an unrecognized "has not been trusted" line as untrusted and does not drop it | PASS |
| III. Least-privilege containment | Trust is granted to exactly two instance paths (T1). `CLAUDE_CODE_SANDBOXED` (trust-everything) was rejected. Trust makes the *committed* pack apply as written, so it does not widen access beyond what the operator committed. The deny side (hook) runs regardless (R3). The gate depends on the profile, and that is legitimate: Principle III's "identical under both profiles" list names the correctness gates (drift, substance, incomplete, analyze, clarify). Whether the pack was applied is a containment question, and the spec's Clarifications assign it to the profile | PASS |
| IV. Cost-bounded autonomy | No retry, so no repeat spend. The breaker and drain are untouched. The cost of the failed phase is accounted as today | PASS |
| V. Human-in-the-loop | No gate diversion is affected. The new reason is `:failed`, and the operator resumes after trusting | PASS (n/a) |
| VI. Idiomatic OTP | The collector is a supervised short-lived process under `SessionSup`. No mailbox sharing with `AgentServer`. Pure parsing is kept apart from process code | PASS |
| VII. Operator surfaces tell the truth | The reason renders with real identifiers (`untrusted_workspace`, `projects["…"].hasTrustDialogAccepted`, `resume/2`) and the CLI-named path. No `inspect/1` (G-inspect). No new color or status | PASS |
| Quality & test discipline | The hermetic suite covers the parser, gate order, retry, renderers and env line. The real entrypoint step runs in tests, as `scope_guard_test` runs the real hook. Docker/agent checks are by-hand smoke (opt-in, like 034) | PASS |
| Development workflow | Spec Kit loop. No in-place amendment of shipped specs (031's env contract is amended by this feature's own contract) | PASS |

**Post-design re-check (after Phase 1)**: unchanged. All PASS. No complexity violations.

## Project Structure

### Documentation (this feature)

```text
specs/036-container-workspace-trust/
├── plan.md                         # this file
├── research.md                     # R1–R8 (trust keying probe, hook finding, stderr channel, gate order)
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── container-trust-step.md     # entrypoint step, guarantees T1–T5, smoke checks
│   ├── environment.md              # AUTONOMOUS_WORKTREE_ROOT (amends 031)
│   ├── untrusted-workspace-gate.md # parser, capture, decision, Pipeline order, retry
│   └── operator-surfaces.md        # report / console / docs wording
└── tasks.md                        # /speckit-tasks
```

### Source Code (repository root)

```text
scripts/
├── container-entrypoint.sh      # + trust_workspaces (step 4c), + `trust-config` subcommand
└── container-smoke.sh           # + `trust` section, + `us-trust-hook` (SMOKE_AGENT)

lib/autonomous/
├── workspace_trust.ex           # NEW pure: parse_line/1, observe/1 (CLI wording boundary)
├── workspace_trust/collector.ex # NEW per-session stderr line collector (under SessionSup)
├── instance.ex                  # env_lines/1 + AUTONOMOUS_WORKTREE_ROOT
├── layout.ex                    # extract worktree_root/2 (shared with Instance)
├── phase_request.ex             # session_metadata: + stderr callback (logs + forwards)
├── phase_result.ex              # + untrusted_workspace field
├── pipeline.ex                  # + untrusted_workspace clause (after session_died)
├── phase_step.ex                # retry_reason/1 → nil for untrusted
├── chunk_runner.ex, chunking.ex # signal at chunk sites; no died-retry on it
├── analyze_runner.ex            # analyze + remediation sessions
├── feature_runner.ex            # remediation_failure_reason clause
├── report.ex                    # format_reason/1 clause
├── actions/run_feature_phase.ex
├── actions/run_auto_remediation.ex
├── actions/run_remediation.ex
└── web/live/run_detail_live.ex  # legacy pass-through clause

test/
├── autonomous/workspace_trust_test.exs        # NEW parser against captured lines
├── autonomous/container_trust_step_test.exs   # NEW runs real `entrypoint trust-config` (python3)
├── autonomous/{pipeline,phase_step,report,instance,layout,chunking,chunk_runner}_test.exs  # extended
└── fixtures/cli_stderr/*.txt                  # NEW real CLI lines (2.1.294 probe; 2.1.286 from smoke)

docs/
├── container.md                 # + Workspace trust section (finding, version, procedure)
└── runbook.md                   # + untrusted_workspace recovery
CLAUDE.md                        # + one paragraph (feature 036)
```

**Structure Decision**: Single OTP project, same layout as features 031/034.
The container step stays inline in `container-entrypoint.sh`, because the
release image copies only that script. A separate helper file would need a new
`COPY`, and the seed step (034) already sets the inline-`python3` precedent.

## Complexity Tracking

No violations. Nothing to justify.
