# Contract: constitution amendment (FR-017)

The feature carries its own governing-document change. This file is the draft
text and the amendment's acceptance criteria; the edit itself lands in
`.specify/memory/constitution.md` during implementation, per the Governance
section's procedure (Sync Impact Report + semantic version bump).

## 1. Version

`1.1.0 → 1.2.0` — **MINOR**. An existing principle is materially expanded (a new
bounded exception plus a new guarantee). Nothing is removed, and no principle
becomes backward-incompatible: the human-facing outcome for a finding the loop
cannot fix is unchanged.

## 2. Principle V — before

> The analyze gate MUST halt to `:halted` on a constitution Critical finding.

## 3. Principle V — after (draft)

> The analyze gate MUST halt to `:halted` on a constitution Critical finding and
> escalate to `:escalated` on a High one. A **bounded, pre-gate auto-remediation
> loop** MAY attempt to fix findings at or above a configured severity threshold
> before the gate is evaluated, subject to all of:
>
> - it runs **strictly before** the gate decides, never after — a gate diversion
>   is still never retried;
> - it is bounded by a per-run attempt limit (1–5, default 2) that MUST NOT be
>   exceeded within one feature run;
> - on exhaustion the gate decides the outcome from the **final** analyze run
>   under the rules above, unchanged, with a recorded reason naming exhausted
>   auto-remediation;
> - every attempt and every analyze re-run is subject to the cost breaker of
>   Principle IV and is individually recorded;
> - it is switchable per run, and disabling it MUST restore fail-fast behaviour
>   exactly.
>
> Escalated and halted features MUST retain their worktree for post-mortem; only
> `:done` features remove it. A human resolution path (`resolve/1`) MUST let a
> feature re-run on its existing branch.

## 4. What the amendment must not touch

Restated verbatim, unchanged, and asserted by review:

- The clarify gate's `## NEEDS HUMAN` escalation.
- "The pipeline MUST NOT fabricate resolution of ambiguity or of a quality
  failure."
- The never-retry-a-gate-diversion rule in Development Workflow.
- Principles I, II, III, IV, VI, the Technology Stack, and Quality & Test
  Discipline.

## 5. Sync Impact Report (to be prepended)

```text
Version change: 1.1.0 → 1.2.0
Bump rationale: MINOR — Principle V materially expanded to permit a bounded,
  pre-gate auto-remediation loop with a halt-on-exhaustion guarantee; no
  principle removed or made backward-incompatible.
Modified principles:
  - V. Human-in-the-Loop Escalation (bounded pre-gate loop + guarantees)
Added principles: none
Added sections: none
Removed sections: none
Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check is
     principle-agnostic; no change needed
  ✅ .specify/templates/spec-template.md — no principle-specific references
  ✅ .specify/templates/tasks-template.md — no principle-specific references
  ✅ .specify/templates/checklist-template.md — generic; no change
Follow-up TODOs: none
```

## 6. Acceptance criteria

- [ ] `.specify/memory/constitution.md` carries the amended Principle V and the
      Sync Impact Report, and reads `**Version**: 1.2.0` with `Last Amended`
      updated.
- [ ] The prior report block is retained (the file keeps its report history).
- [ ] No other principle's text changes (verifiable by diff).
- [ ] `CLAUDE.md`'s architecture section mentions the loop where it describes
      the analyze gate, so the runtime guidance and the constitution agree.
