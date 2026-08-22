# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]

**Input**: Feature specification from `/specs/[###-feature-name]/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

[Extract from feature spec: primary requirement + technical approach from research]

## Technical Context

<!--
  ACTION REQUIRED: Replace the content in this section with the technical details
  for the project. The structure here is presented in advisory capacity to guide
  the iteration process.
-->



*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Answer each gate explicitly. "N/A" is allowed but MUST state why the feature cannot touch
that concern. Any failure requires an entry in Complexity Tracking below.

- [ ] **I. Deterministic Simulation** — Does this feature touch simulation state? If yes:
      it lands in `packages/sim` with no render/Electron/DOM/Node-API imports, fixed 60 Hz
- [ ] **II. Data-Driven Content** — No balance or content value hardcoded in TypeScript.
      New or changed content lives in `content/*.json` with a `formatVersion` and an
- [ ] **III. Accessibility Is a Release Gate** — No gameplay-critical information conveyed
      by colour alone; resistance emblems always rendered on their own top layer. Emblems
- [ ] **V. Run Integrity & Player Data Custody** — Score submissions carry the full audit
      payload and are re-simulable; user-map scores stay on per-map boards and never reach

```
packages/sim/
```


**Structure Decision**: [Document the selected structure and reference the real
directories captured above]

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
