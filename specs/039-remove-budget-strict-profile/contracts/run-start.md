# Contract: Run start, resume and continue (039)

Supersedes the budget/profile parts of `specs/019-stacked-sequential-only/contracts/run-start.md`
and `specs/030-permissive-containment/` for run start. Decisions: research R4, R6, R9.

## 1. Retired options (refused first, before any side effect)

Entry points: `Autonomous.run/1`, `run_spec/2`, `resume/2`, `resume_run/1`,
`continue_run/1` (and the console Trigger/Escalations/Mission Control actions
that call them).

| Supplied option | Result |
|---|---|
| `budget_usd: _` (any value, incl. `nil`) | `{:error, {:preflight, [{:retired_option, :budget_usd}]}}` |
| `containment_profile: _` (any value) | `{:error, {:preflight, [{:retired_option, :containment_profile}]}}` |
| both | one tuple listing both keys, in `@retired_opts` order |
| `pr_workflow` / `max_concurrency` | unchanged (019) |

Guarantees:
- No run record is opened, no Coordinator started, no worktree created, no
  parked run flipped (continue stays `:parked`, byte-identical — feature 035).
- The rendered message names the key and says why it is gone
  (`budget_usd`: "cost is informational; runs never stop on spend";
  `containment_profile`: "there is one containment behaviour; run in the
  container").

## 2. Retired configuration (refused at boot)

| Source | Result |
|---|---|
| `config :autonomous, budget_usd:` | `Application.start` raises naming `:budget_usd` |
| `config :autonomous, containment_profile:` | raises naming `:containment_profile` |
| env `AUTONOMOUS_BUDGET_USD` set (any value) | `config/runtime.exs` raises naming it |
| env `AUTONOMOUS_CONTAINMENT_PROFILE` set (any value) | `config/runtime.exs` raises naming it |
| `LiveConfig` change on `:budget_usd` | `{:error, …}` naming `budget_usd` as retired; nothing applied |

## 3. Preflight order (fresh run)

1. retired options (§1)
2. existing checks (store, active-run guard, …) — unchanged
3. `TargetPack.verify(repo)` — no `:profile` option; always runs the pack
   contract check ([target-pack.md](target-pack.md))
4. container notice: if `RuntimeNotice.container_warning(ContainerGuard.containerized?())`
   is non-nil → `Logger.warning/1` with that text; **never** an error
5. start

Resume/continue: same, minus fresh-run-only steps; no profile is read from,
compared to, or written to the stored run (`guard_containment_profile/2` and
`{:containment_profile_locked, _}` no longer exist).

## 4. Container notice text (contract for tests)

`RuntimeNotice.container_warning(true) == nil`.
`RuntimeNotice.container_warning(false)` is a multi-line string that:
- states the run is starting **outside** the container;
- states sessions run with full tool access and no in-tree deny list;
- names `scripts/autonomous` as the supported runtime;
- states the run proceeds.

## 5. What a run no longer does

- never reserves or checks a budget;
- never halts, drains, or refuses because of spend (any phase, chunk,
  remediation attempt, clarify wait, or release);
- never sends `AUTONOMOUS_ORCHESTRATED` / `AUTONOMOUS_CONTAINMENT_PROFILE`
  to a session;
- still drains on supersession (`Workers.drain_requested?/0`) and still stops
  releasing when the store is unwritable (`Release.next/3` `blocked?`).
