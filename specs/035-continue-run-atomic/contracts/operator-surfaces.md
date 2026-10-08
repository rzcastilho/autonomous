# Contract: Operator surfaces (035)

## Mission Control (`MissionControlLive`)

- After a refused continue the stored run is `:parked`, so the existing
  parked panel (`data-action="continue-run"` / `data-action="end-run"`)
  renders unchanged (FR-006). No markup change.
- Flash on refusal: unchanged string, `"Continue failed: " <> inspect(reason)`
  (FR-005). For FR-009 the reason is
  `{:continue_restore_failed, reason, restore_error}` — both causes visible.

## Escalations (`EscalationsLive.dispatch_resume/2`)

- Unchanged dispatch; inherits continue's guarantee (US3).

## Run Detail (`RunDetailLive`)

New block, rendered only when `run.continue_restore_failure` is non-nil:

```text
<div data-marker="continue-restore-failure">
  continue_run/1 refused and could not restore :parked
  refusal:        <mono>{refusal}</mono>
  restore error:  <mono>{restore_error}</mono>
  at:             <mono>{at, ISO-8601}</mono>
  recover with:   <mono>resume/2</mono>
</div>
```

Design contract (Principle VII / `docs/design-constitution.md`):
- machine values (`refusal`, `restore_error`, timestamp, `resume/2`,
  `:parked`) in mono, prose in sans;
- colour via existing tokens only, `data-status="failed"` semantics — no new
  token, no inline style (design-contract guard G-*);
- no raw `inspect/1` in markup (G-inspect): the stored values are already
  strings.
- Absent when `nil` — every run without the annotation renders
  byte-identically (FR-008).

## `Report` / `print_status/0`

No change: neither renders run-level annotations today.
