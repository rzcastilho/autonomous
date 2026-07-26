# Tasks: Prose Plan (fixture — no checkboxes, no task-phase headings)

A hand-written plan with no `- [ ]`/`- [X]` checkbox syntax at all and no
`## Phase <n>: <title>` headings. `TaskPlan.parse/2` must yield
`structured?: false` and vacuous `complete?: true` (there are zero incomplete
tasks because there are zero tasks).

## Plan

First set up the project, then write the core module, then add tests, then
document the feature. No checkboxes are used to track progress in this plan.
