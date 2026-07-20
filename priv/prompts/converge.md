This is the `converge` step. The feature has been implemented. Bring the feature
branch to a state that is **ready for human PR review** — do not merge.

Do:

1. Run the project's test suite and ensure it passes. Fix failing tests that are
   caused by this feature's implementation.
2. Ensure the working tree is committed on the feature branch with a clear
   message.
3. Confirm the implementation satisfies the spec's acceptance criteria and does
   not violate `.specify/memory/constitution.md`.

Do NOT:

- Merge the branch, open a PR, or push to any protected branch.
- Introduce changes outside this feature's scope.

End with a short plain-text summary of the branch state (tests green/red,
commits made, any residual risk for the human reviewer).

Then end your response with **exactly one** of these two lines, on its own line,
as the very last line:

    ## CONVERGE: READY

    ## CONVERGE: NOT READY

Use `NOT READY` whenever the feature is not actually built — no plan, no tasks,
no implementation code, acceptance criteria unsatisfiable, or the suite is red
because of this feature. This line is read by the orchestrator's converge gate:
`NOT READY` fails the feature and keeps the worktree for inspection instead of
opening a pull request. Do not write the marker in prose anywhere else.
