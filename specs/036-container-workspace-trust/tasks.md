# Tasks: Container Workspace Trust

**Input**: Design documents from `/specs/036-container-workspace-trust/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (container-trust-step, environment, untrusted-workspace-gate, operator-surfaces), quickstart.md

**Tests**: Included. The plan and quickstart §1 specify a hermetic suite (parser, gate order, retry, renderers, env line, real `trust-config` step). Run Elixir via `mise exec -- mix test …`; `warnings_as_errors` is on.

**Organization**: Grouped by user story. US1 holds both the container trust step and the FR-013 untrusted-workspace gate (spec scenarios 1–5). US2/US3 harden and prove the trust step. US4 records the hook finding.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1–US4 from spec.md

---

## Phase 1: Setup

**Purpose**: Fixtures and scaffolding shared by later phases.

- [X] T001 [P] Create `test/fixtures/cli_stderr/` with real captured CLI lines as separate `.txt` files: `allow_untrusted.txt` (`Ignoring 6 permissions.allow entries from .claude/settings.json: this workspace has not been trusted. … set projects["/x/repo"].hasTrustDialogAccepted: true in /home/u/.claude.json.`), `additional_dirs_untrusted.txt` (`Ignoring 1 permissions.additionalDirectories entry from …`), `no_cwd.txt` (`… a session with no working directory is never trusted.`), `unparsable_untrusted.txt` (contains `has not been trusted` but no `projects[...]`), `unrelated.txt` (ordinary stderr line). Source: research.md R2 and contracts/untrusted-workspace-gate.md §1 table.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Pure pieces and plumbing every story depends on: worktree-root derivation, the env line, the parser, and the `trust-config` entrypoint subcommand skeleton.

- [X] T002 Extract `Layout.worktree_root(autonomous_root, segment)` as a public function (`Path.join([autonomous_root, "worktrees", segment])`) in `lib/autonomous/layout.ex` and make both existing call sites (lines ~100 and ~112) use it. Behaviour unchanged.
- [X] T003 [P] Add `test/autonomous/layout_test.exs` case asserting `Layout.worktree_root/2` equals the `worktree_root` field of the struct built for the same root/segment (extend the existing file if present).
- [X] T004 Extend `Autonomous.Instance.env_lines/1` in `lib/autonomous/instance.ex` to emit `AUTONOMOUS_WORKTREE_ROOT=<Layout.worktree_root(autonomous_root, segment)>` as the **last** line (six identity lines total), per contracts/environment.md.
- [X] T005 [P] Extend `test/autonomous/instance_test.exs`: `env_lines/1` yields six lines, last is `AUTONOMOUS_WORKTREE_ROOT=…`, value equals `Layout.worktree_root/2` for the same repo/root; the first five lines are unchanged.
- [X] T006 [P] Create pure module `lib/autonomous/workspace_trust.ex` with `parse_line/1` and `observe/1` per contracts/untrusted-workspace-gate.md §1: key on `this workspace has not been trusted` and `a session with no working directory is never trusted`; extract `projects["<path>"]` key and `<kind>` (`permissions.allow` | `permissions.additionalDirectories`); an untrusted line with no parsable key returns `{:untrusted, %{workspace: nil, kind: nil}}`; anything else `:other`. `observe/1` returns `nil` or `%{workspace: first non-nil, kinds: deduped in order seen}`. Add `@moduledoc` stating this is the only module that knows the CLI wording.
- [X] T007 [P] Create `test/autonomous/workspace_trust_test.exs` asserting every fixture in `test/fixtures/cli_stderr/` (T001) parses as the contract table says, `observe/1` of `[]`/unrelated lines is `nil`, and multi-line input dedupes kinds in first-seen order. Depends on T001, T006.
- [X] T008 Add `trust-config` subcommand skeleton to `scripts/container-entrypoint.sh` next to the existing `seed-config` dispatch (line ~66): runs `seed_cli_config` then `trust_workspaces` and exits 0, before build/identity/lock work, reading `AUTONOMOUS_REPO`/`AUTONOMOUS_WORKTREE_ROOT` from the environment. (`trust_workspaces` body is implemented in T010; define it as a stub returning 0 here only if needed to keep the script runnable, replaced in T010.)

**Checkpoint**: Parser, env line and subcommand entry exist; stories can start.

---

## Phase 3: User Story 1 — Orchestrated sessions honour the committed pack (Priority: P1) 🎯 MVP

**Goal**: Containerized sessions are trusted (no warning), and any session that still reports an untrusted workspace fails the phase under `strict` (not retried) or warns under `permissive`, on container and host alike.

**Independent Test**: `trust-config` against a temp `HOME` writes both trust records; `Pipeline.next/3` with an `untrusted_workspace` signal returns `{:untrusted_workspace, phase, obs}`; quickstart §2–§3, §5.

### Tests for US1 (write first, expect failure)

- [X] T009 [P] [US1] Create `test/autonomous/container_trust_step_test.exs` (style of `scope_guard_test`; requires `python3`): runs the real `scripts/container-entrypoint.sh trust-config` with a temp `HOME`, `AUTONOMOUS_REPO` and `AUTONOMOUS_WORKTREE_ROOT` (the latter not yet existing). Cases: no config → file created with `projects` holding exactly `realpath(repo)` and `realpath(root)` each `hasTrustDialogAccepted: true`, mode `0600`, exit 0; path with spaces is a correct key; second run → exit 0 and file bytes + mtime unchanged; missing/empty `AUTONOMOUS_WORKTREE_ROOT` → non-zero exit naming the variable.
- [X] T010 [P] [US1] Extend `test/autonomous/pipeline_test.exs`: with signal `untrusted_workspace: obs` the outcome is `{:failed, {:untrusted_workspace, phase, obs}}` (match the shape existing `:session_died` tests assert) for session status `:ok` **and** `:error`; precedence: `branch_drift` and `session_died` beat it, it beats `backgrounded` and `incomplete_session`; with no signal every existing outcome is unchanged (U3).
- [X] T011 [P] [US1] Extend `test/autonomous/phase_step_test.exs`: `PhaseStep.retry_reason/1` returns `nil` for `{:untrusted_workspace, _, _}` (and the phase is not retried end-to-end).
- [X] T012 [P] [US1] Extend `test/autonomous/report_test.exs`: `Report.format_reason/1` renders `untrusted_workspace in <where> — CLI ignored <kinds> from the committed pack; workspace <path> is not trusted (projects["<path>"].hasTrustDialogAccepted). Trust it, then resume/2.`; empty kinds → `(unknown)`; `workspace: nil` → `session had no working directory` clause; `<where>` forms (phase atom, chunk ref, `{:remediation, n}`) match how `:session_died` renders.
- [X] T013 [P] [US1] Extend `test/autonomous/phase_result_test.exs`: new `untrusted_workspace` field defaults to `nil` and is carried through the same constructors/accessors as the existing gate fields.
- [X] T014 [P] [US1] Add `test/autonomous/workspace_trust/collector_test.exs`: collector started under `Autonomous.SessionSup` accumulates lines sent to it, returns them in order on read, is stopped by the reader, and a send to a stopped collector is dropped without raising.
- [X] T015 [P] [US1] Extend `test/autonomous/phase_request_test.exs` (create if absent): `session_metadata/2` includes `metadata["claude"][:stderr]` as a 1-arity function; invoking it logs `CLI stderr: <line>` (capture_log) and forwards only lines where `WorkspaceTrust.parse_line/1 != :other` to the collector.
- [X] T016 [P] [US1] Add site-decision tests (new `test/autonomous/untrusted_gate_test.exs` or extend the existing action tests): strict + observation → `untrusted_workspace` signal set; permissive + observation → no signal and a `Logger.warning` matching `untrusted workspace <path>: CLI ignored <kinds> from the committed pack; continuing under permissive`; no observation → no signal under either profile (U1–U3). Exercise `RunFeaturePhase`, `RunAutoRemediation`, `RunRemediation`, and the implement-chunk path (`Chunking`/`ChunkRunner`) through whatever injected session seam they already use in tests.

### Implementation for US1 — container trust step

- [X] T017 [US1] Implement `trust_workspaces` in `scripts/container-entrypoint.sh` (inline `python3`, per research R6 / contracts/container-trust-step.md): require `HOME`, `AUTONOMOUS_REPO`, `AUTONOMOUS_WORKTREE_ROOT` (die naming the variable if the worktree root is empty); `os.path.realpath` both paths; load `$HOME/.claude.json` (absent → `{}`; **not** JSON / not an object / `projects` not an object → `die "container CLI config $HOME/.claude.json is not a JSON object: <msg>; not modified"` without touching the file); set `projects[p].hasTrustDialogAccepted = true` for exactly those two paths keeping every other key; if nothing changed log `autonomous: <repo> and <root> already trusted for agent sessions` and do not write; otherwise write `$HOME/.claude.json.tmp.<pid>` with `O_CREAT|O_EXCL`, mode `0600`, `fsync`, then `os.replace`; log `autonomous: trusted <repo> and <root> for agent sessions`. Replaces the T008 stub.
- [X] T018 [US1] Call `trust_workspaces` as step 4c in the main entrypoint flow in `scripts/container-entrypoint.sh`, immediately after `seed_cli_config` (line ~211) and before warnings and the VM `exec`, so it applies to the `shell`, `console` and `release` shapes alike (FR-009).

### Implementation for US1 — untrusted-workspace gate

- [X] T019 [P] [US1] Create `lib/autonomous/workspace_trust/collector.ex`: small per-session line collector process (GenServer or Agent) started under `Autonomous.SessionSup`, API `start/0`, `push/2` (cast; dropped if the process is gone), `lines/1` (ordered), `stop/1`. No mailbox sharing with `AgentServer`.
- [X] T020 [P] [US1] Add `untrusted_workspace` field (default `nil`, type `WorkspaceTrust.observation() | nil`) to `lib/autonomous/phase_result.ex`, following the existing gate-field conventions there.
- [X] T021 [US1] Update `PhaseRequest.session_metadata/2` in `lib/autonomous/phase_request.ex` to add `:stderr` to `metadata["claude"]`: a callback that logs `Logger.warning("CLI stderr: " <> line)` exactly as the SDK default did and forwards matching lines (via `WorkspaceTrust.parse_line/1`) to the session's collector (collector pid passed in as an argument/option so the function stays testable). Depends on T006, T019.
- [X] T022 [US1] Add the `untrusted_workspace` clause to `Pipeline.next/3` in `lib/autonomous/pipeline.ex`, after `session_died` and before `backgrounded_command`, applying whether session status is `:ok` or `:error`, producing `{:untrusted_workspace, phase, obs}` with terminal status `:failed`; no signal ⇒ byte-identical to before. Update the `@moduledoc`/gate-order docs. Depends on T020.
- [X] T023 [US1] Add a short-circuit in `PhaseStep.retry_reason/1` in `lib/autonomous/phase_step.ex` returning `nil` for `{:untrusted_workspace, _, _}` (same as branch drift). Confirm `SessionRetry.once/2` and the `Chunking` died-retry do not fire on it (adjust `lib/autonomous/session_retry.ex` / `lib/autonomous/chunking.ex` only if they would).
- [X] T024 [US1] Add a shared helper (e.g. `WorkspaceTrust.signal_or_warn(collector_lines, profile, phase)` or a small function in `lib/autonomous/phase_step.ex`) implementing the decision in contracts/untrusted-workspace-gate.md §3: `observe/1` → `nil` (no signal) | strict (return signal) | permissive (`Logger.warning` text from the contract, no signal). Containment profile is read via the same accessor the other profile-aware sites use (`Containment`/run settings), not from CLI state.
- [X] T025 [US1] Wire collector start/read/stop and the T024 decision at `lib/autonomous/actions/run_feature_phase.ex`: start collector before `Jido.Harness.run_request/3`, pass it to `PhaseRequest`, read+stop after `PhaseSession.reduce/2` returns on **every** outcome (incl. deadline and session death), put the signal into `last_signals` and `PhaseResult`.
- [X] T026 [P] [US1] Same wiring in `lib/autonomous/actions/run_auto_remediation.ex`.
- [X] T027 [P] [US1] Same wiring in `lib/autonomous/actions/run_remediation.ex`.
- [X] T028 [P] [US1] Same wiring for implement-chunk sessions in `lib/autonomous/chunk_runner.ex` and `lib/autonomous/chunking.ex` (signal reaches the chunk failure reason; no died-retry on it).
- [X] T029 [P] [US1] Same wiring for analyze and its remediation sessions in `lib/autonomous/analyze_runner.ex`.
- [X] T030 [US1] Add the `{:untrusted_workspace, …}` clause to `FeatureRunner.remediation_failure_reason` in `lib/autonomous/feature_runner.ex` so remediation-site failures terminate the feature `:failed` with the reason; confirm commit + `keep_for_inspection` behaviour matches other non-drift `:failed` terminals (contracts/untrusted-workspace-gate.md §6).
- [X] T031 [P] [US1] Add the `format_reason/1` clause in `lib/autonomous/report.ex` per contracts/operator-surfaces.md (reuse the `where` helper `:session_died` uses; no `inspect/1`).
- [X] T032 [P] [US1] Add the pass-through clause in `lib/autonomous/web/live/run_detail_live.ex` alongside the existing `:backgrounded_command`/`:session_died` legacy clauses; path in mono, ellipsized, no new color/token. Run `mise exec -- mix test test/autonomous/design_contract_test.exs` to confirm guards (`G-inspect`, etc.) stay clean.

**Checkpoint**: US1 complete — `mise exec -- mix test` green; trust step and gate work independently of US2–US4.

---

## Phase 4: User Story 2 — Trust never reaches beyond this instance (Priority: P1)

**Goal**: Exactly two paths trusted by this feature; no ancestors; host config never written.

**Independent Test**: Inspect `projects` after `trust-config`; host file hash unchanged across a `--with-login` start/stop.

- [X] T033 [P] [US2] Extend `test/autonomous/container_trust_step_test.exs`: after the step, set of paths added by the step is exactly `{realpath(repo), realpath(root)}`; none of `$HOME`, `/`, the parent `$AUTONOMOUS_ROOT`, or `/workspace` appears; a pre-seeded third path (true) and a pre-seeded `false` entry for another path are carried over unchanged; two different instances (different repo/root, separate `HOME`s) trust only their own pair.
- [X] T034 [P] [US2] Extend the same test: with a seed-config scenario (host file path env as `seed_cli_config` expects, read-only), the host file's bytes are identical before and after `trust-config`, and only `$HOME/.claude.json` is written (T4).
- [X] T035 [US2] Audit `trust_workspaces` in `scripts/container-entrypoint.sh` for T1/T4: it must reference only `$HOME/.claude.json` and the two env paths; no wildcard/ancestor logic; fix any gap found by T033/T034.
- [X] T036 [US2] Add the `trust` section to `scripts/container-smoke.sh` (dispatch at line ~615 and usage string at ~625: `[us1|…|us6|secrets|trust|us-trust-hook]`) with the **exact trusted set** check and the **host `~/.claude.json` sha256 unchanged** check around a `--with-login` instance start + stop (contracts/container-trust-step.md §Smoke checks).

**Checkpoint**: US2 verifiable alone via T033–T035 and `scripts/container-smoke.sh trust`.

---

## Phase 5: User Story 3 — Existing configuration survives intact (Priority: P2)

**Goal**: Merge preserves every key; invalid file stops startup untouched; replace is atomic; idempotent across restarts.

**Independent Test**: Seed config with unrelated keys + explicit `false` for the repo; run step 1/2/5 times.

- [X] T037 [P] [US3] Extend `test/autonomous/container_trust_step_test.exs`: seeded config with credentials-like unrelated top-level keys, nested project-entry keys (e.g. `allowedTools`, `history`) and key order → all preserved by JSON value equality and order after the step; repo explicitly `false` becomes `true`.
- [X] T038 [P] [US3] Extend the same test: invalid configs (`{`, `[]`, `"x"`, `{"projects": []}`) → non-zero exit, stderr names `$HOME/.claude.json`, file bytes unchanged; absent config → created `0600`; run N=1,2,5 times → bytes identical after run 1 and exactly two records added.
- [X] T039 [P] [US3] Extend the same test: atomicity — after a successful write no `.claude.json.tmp.*` file is left behind, and the final file is never the in-place-modified original inode (assert via `stat` inode change on a modifying run).
- [X] T040 [US3] Fix any preservation/atomicity/idempotence gaps in `trust_workspaces` found by T037–T039 (`scripts/container-entrypoint.sh`).
- [X] T041 [US3] Extend the `trust` smoke section in `scripts/container-smoke.sh` with: seeded-config preservation (original keys equal, third path untouched), idempotence across 1/2/5 runs (SC-002), and invalid-config refusal (non-zero, file byte-identical). Agent check under `SMOKE_AGENT=1`: one `claude -p` in a worktree of a scratch target with `permissions.allow` entries → stderr has no `has not been trusted`; otherwise report `SKIP`.

**Checkpoint**: US3 verifiable alone via T037–T039.

---

## Phase 6: User Story 4 — Operator knows whether strict containment held while untrusted (Priority: P2)

**Goal**: Reproducible hook-under-untrusted check, finding recorded with date and CLI version.

**Independent Test**: `SMOKE_AGENT=1 scripts/container-smoke.sh us-trust-hook`.

- [X] T042 [US4] Add the `us-trust-hook` section to `scripts/container-smoke.sh` (only runs with `SMOKE_AGENT=1`, else `SKIP`): scratch target with the shipped pack (`TargetPack.install/2`, committed); container config with no trust record; session with `AUTONOMOUS_ORCHESTRATED=1` and `AUTONOMOUS_CONTAINMENT_PROFILE=strict` asked to write `/tmp/outside`; record untrusted-warning present?, `scope_guard` deny line present?, file written?; then add the repo trust record and repeat, expecting denied. Print a machine-greppable result line including `claude --version`.
- [ ] T043 [US4] Run T042 against the pinned image (CLI 2.1.286) once by hand and capture the result; also keep the host 2.1.294 probe (research R3) as the provisional note. If the hook did **not** run while untrusted on 2.1.286, record that plainly and open a follow-up note in `docs/container.md` instead of changing scope.
- [X] T044 [US4] Add a *Workspace trust* section to `docs/container.md`: what is trusted and why (repo record load-bearing, worktree keys resolve to the main repo — research R1; worktree-root record bounded/forward-compatible); login-seeded trust carried over untouched; the hook finding with date, CLI version and outcome from T043; the reproducible procedure (quickstart §4, under 10 minutes — SC-005); implication for past strict runs (ran narrower, not wider — R3, adjusted if T043 differs).

**Checkpoint**: All four stories independently verifiable.

---

## Phase 7: Polish & Cross-Cutting

- [X] T045 [P] Add the `untrusted_workspace` recovery entry to `docs/runbook.md`: on the host, run `claude` interactively once in the target repo and accept the trust dialog (one record covers all worktrees), then `Autonomous.resume/2` from the failed phase; note permissive only warns.
- [X] T046 [P] Add one paragraph for feature 036 to `/CLAUDE.md` (repo root `CLAUDE.md`): container trust step (two records, atomic, idempotent, host untouched), the strict-only untrusted gate (new reason, never retried, after session-died), and the `AUTONOMOUS_WORKTREE_ROOT` env line.
- [X] T047 [P] Amend the environment documentation that lists the five identity variables (search `docs/container.md` and `specs/031-*/contracts/environment.md` references via `grep -rn AUTONOMOUS_COOKIE_PATH docs`) to mention the sixth variable — in `docs/` only; do not edit the shipped 031 spec (constitution: no in-place amendment).
- [X] T048 Run the full hermetic suite `mise exec -- mix test` and `mise exec -- mix compile --warnings-as-errors`; fix regressions (SC-006: existing tests change only where they assert the new behaviour).
- [ ] T049 Walk quickstart.md §1–§6 end to end (§3–§4 need `SMOKE_AGENT=1` and credentials) and confirm each Expected line; note any deviation in `specs/036-container-workspace-trust/research.md`.

---

## Dependencies & Execution Order

- **Setup (P1)** → no deps. **Foundational (P2)** → after Setup (T007 needs T001+T006; T005 needs T004; T003 needs T002; T008 independent).
- **US1 (P3)**: tests T009–T016 can be written once Foundational exists (they fail until implementation). Container step (T017→T018) is independent of the gate chain (T019–T032). Within the gate: T019, T020 [P] → T021 (needs T006, T019), T022 (needs T020), T023, T024 (needs T006) → T025 (needs T021–T024) → T026–T029 [P] → T030, T031, T032.
- **US2 (P4)** depends on T017/T018 (step exists). **US3 (P5)** depends on T017/T018. US2 and US3 both edit `container_trust_step_test.exs` and `container-smoke.sh` — serialize those edits, don't run both stories' file edits concurrently.
- **US4 (P6)** depends on T018 and on the `trust` smoke plumbing (T036) for dispatch/usage line; T043 needs a built image and credentials.
- **Polish (P7)** after the stories it documents.

### Story dependency graph

```text
Setup → Foundational → US1 (MVP) ─┬→ US2 ─┐
                                  ├→ US3 ─┼→ Polish
                                  └→ US4 ─┘
```

## Parallel Execution Examples

- **Foundational**: T003, T005, T006 together after T002/T004 land (T006 touches only `workspace_trust.ex`).
- **US1 tests**: T009–T016 all in different files — write in parallel.
- **US1 gate sites**: after T025 sets the pattern, T026, T027, T028, T029 in parallel (different files); T031 and T032 in parallel.
- **Polish**: T045, T046, T047 in parallel.

## Implementation Strategy

- **MVP = US1**: the trust step (T017–T018) fixes the actual defect; the gate (T019–T032) guarantees it can never silently regress, and applies on the host too. Ship US1 first; validate with `mise exec -- mix test` and quickstart §1–§2, §5.
- **Then** US2 and US3 (proof and hardening of the step; mostly tests plus smoke), then US4 (documentation of the hook finding, needs a live agent run), then Polish.
- Behaviour with no untrusted line must stay byte-identical to pre-036 (U3) — run the full suite after T022 and T025 specifically to catch drift early.
