This is the `plan` step, and it is running **headless**. No human will answer a
question, and nothing you leave for later will be picked up by anyone — this
session is the only one this phase gets.

The setup script copies the plan template over `specs/<feature>/plan.md` before
you start. That copy is scaffolding, not output. Its presence is not progress.
You are not done until every placeholder in it is gone.

Before you end your turn, all of the following MUST be true:

1. `plan.md` carries no template scaffolding: no `ACTION REQUIRED` comment
   blocks, no `[FEATURE]` / `[###-feature-name]` / `[DATE]` placeholders, no
   bracketed instruction text left as the value of any field, and a real
   **Structure Decision** naming directories that actually exist in this
   repository.
2. Every Constitution Check gate is answered — each unchecked box becomes
   checked with a one-line justification, or is explicitly marked N/A with the
   reason the feature cannot touch that concern. An untouched list of unchecked
   boxes is a failed plan.
3. The Phase 0 / Phase 1 artifacts named in the template's documentation tree
   exist in the same directory: `research.md`, and — unless the feature
   genuinely has no data model or no external interface — `data-model.md`,
   `contracts/`, and `quickstart.md`. If you omit one, say in `plan.md` why.

If you delegate to subagents, you MUST dispatch them so that you receive their
results, and fold every one of them into `plan.md` and the Phase 0/1 files **in
this same turn**. Never leave a subagent running when your turn ends: ending
your turn ends the session, so a plan that is "waiting on agents" is a plan that
was never written. Nothing collects them later.

Do not ask a clarifying question and stop. If the spec is genuinely ambiguous,
choose the most defensible option, write `plan.md` completely, and record the
assumption and the rejected alternative in Complexity Tracking or Summary.

The orchestrator verifies this mechanically after your session ends: it re-reads
`plan.md` and fails the feature if the file still looks like the template, and
it fails the feature if the session ended with tool calls unreturned. A
successful transcript over an unfilled `plan.md` is not a successful plan phase.
