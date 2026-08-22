# Implementation Plan: Map Package Save and Load

**Branch**: `006-map-package-save-and-load` | **Date**: 2026-08-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-map-package-save-and-load/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Package a map plus its assets into a single portable archive and load it back with integrity checks.

## Technical Context

TypeScript 5.x strict, Node 22, zlib for CRC32. No new dependencies.



*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Answer each gate explicitly. "N/A" is allowed but MUST state why the feature cannot touch
that concern. Any failure requires an entry in Complexity Tracking below.

- [x] **I. Deterministic Simulation** — Does this feature touch simulation state? If yes:
      it lands in `packages/sim` with no render/Electron/DOM/Node-API imports, fixed 60 Hz
- [x] **II. Data-Driven Content** — No balance or content value hardcoded in TypeScript.
      New or changed content lives in `content/*.json` with a `formatVersion` and an
- [x] **III. Accessibility Is a Release Gate** — No gameplay-critical information conveyed
      by colour alone; resistance emblems always rendered on their own top layer. Emblems
- [x] **V. Run Integrity & Player Data Custody** — Score submissions carry the full audit
      payload and are re-simulable; user-map scores stay on per-map boards and never reach

```
packages/sim/
```


**Structure Decision**: Archive read/write lands in `packages/sim/src/package/`, the
Electron file dialogs in `apps/desktop/src/main/`.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
