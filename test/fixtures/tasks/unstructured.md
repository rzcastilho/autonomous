# Tasks: Legacy Feature (fixture — no task-phase headings)

This task list predates the `## Phase <n>: <title>` convention. It has
checkboxes but no task-phase structure, so `TaskPlan.parse/2` must yield
`structured?: false` and the FR-004 fallback path.

- [X] Set up the project
- [X] Write the core module
- [ ] T014 Add integration tests
- [ ] Document the feature
