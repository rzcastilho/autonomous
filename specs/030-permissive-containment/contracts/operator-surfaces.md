# Contract: operator surfaces (FR-015, SC-003, SC-004)

**Invariant**: for a run whose profile is `strict`, every function below
returns exactly what it returns at `df4b6f3`. Existing snapshot and
LiveView tests are the proof. Markers appear only for `permissive`.

The marker is not a status. It uses no status colour and adds no design
token. It uses the existing neutral chip (`--raised` fill, `--border-strong`
border, `--text`, `--r-chip`, mono font) with the machine value in mono:
`containment: permissive`.

| Surface | Module | Permissive rendering | Test hook |
|---|---|---|---|
| Final report | `Coordinator` report map | `containment_profile: "permissive"` | `coordinator_test` |
| Status snapshot | `Coordinator.status/0` | same key | `coordinator_test` |
| iex status | `Report.format_status/1` | line `containment: permissive (no pack deny list)` after the spend line | `report_test` |
| Topbar, every view (Mission Control included) | `Layouts` topbar | chip with `data-containment="permissive"` | `mission_control_live_test` |
| Run Detail | `RunDetailLive` | `CONTAINMENT` block: `containment_profile: permissive`, plus a hint to the enforcement guide | `run_detail_live_test` |
| Run Detail SETTINGS chips | `RunDetailLive` | shows `containment_profile: permissive` | the chip list **skips** `containment_profile` when `strict` |
| Configuration | `ConfigLive` | row `containment_profile default: permissive` (when the default is permissive) and the live run's profile (when a live run is permissive) | `config_live_test` |
| PR body | `pr_text/2` in `lib/autonomous.ex` | body `<> Remediation.pr_note(…) <> Containment.pr_note(profile)` | `pull_request_test` |

`Containment.pr_note("permissive")`:

```text

---
**Containment: permissive.** This feature was built with relaxed
containment: the orchestrator's pack applied no deny list, and every phase
had full write, Bash and network access. Review side effects outside the
diff (pushes, network calls, writes outside the worktree) accordingly.
```

`Containment.pr_note("strict")` and `pr_note(nil)` return `""`.

The profile read for the PR comes from the recorded run
(`RunSettings.settings["containment_profile"]`), so a publish-only resume
writes the same note as the original publish would have.

Design guard: `test/support/design_contract.ex` must stay green. No new
colour, radius, font-size or spacing literal.
