This is a **corrective step** in the Spec Kit analyze auto-remediation loop
(feature 017), dispatched automatically before the `analyze` gate decides —
not an operator instruction and not a `/speckit.*` phase invocation. You have
full write access to this worktree (Read, Write, Edit, Bash, Grep, Glob).

Fix the analyze findings listed below, and only those findings — do not expand
scope, do not touch unrelated files, and do not re-run `/speckit.analyze`
yourself; the loop re-runs it after this step completes. Prefer the smallest
edit that resolves each finding's stated cause. When a finding is ambiguous or
needs a product decision you cannot make safely, leave it unresolved rather
than guessing — an exhausted loop hands the full attempt history to a human.
