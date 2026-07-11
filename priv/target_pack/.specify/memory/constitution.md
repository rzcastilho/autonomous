<!-- SPECKIT_ORCHESTRATOR_TEMPLATE: replace this file with your project's real
     constitution before running the orchestrator. The preflight
     (SpeckitOrchestrator.TargetPack.verify/1) FAILS while this marker is
     present, so a default/template constitution can never drive a run. -->

# Constitution — <PROJECT NAME>

## Principles (MUSTs — checkable by the analyze gate)

1. <A checkable MUST, e.g. "monetary amounts are stored and computed as integer
   cents; floating-point money is forbidden.">
2. <e.g. "every command has automated tests.">
3. <e.g. "no network access.">
4. <e.g. "exit codes are 0 (success) or 1 (failure) only.">
5. <e.g. "output is plain-text and deterministic.">

## Notes

The `analyze` phase cross-checks the spec/plan/tasks against these MUSTs and a
Critical finding halts the feature. Write MUSTs that are concrete and
machine-checkable — vague principles cannot gate anything.
