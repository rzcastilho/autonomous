You are writing the **commit message** and the **pull-request description** for a
feature the autonomous pipeline just finished building. Be accurate and specific
— base everything on the actual spec and the real diff, never on assumptions, and
never invent changes that are not in the diff.

Inspect (read-only, via the Bash and Read tools):

- `specs/<feature>/spec.md` and `plan.md` — what the feature is and how it was
  designed.
- The actual changes on this branch — run `git diff`, `git log --oneline`, and
  `git status` to see exactly what changed (new files, modified modules, tests).

Then output, as the **final** content of your response, **exactly one JSON
object** and nothing after it:

```json
{
  "commit_message": "type(scope): imperative subject <=72 chars\n\nA short body (wrapped ~72 cols) explaining what changed and why. Conventional Commits style.",
  "pr_title": "Concise PR title, <=72 chars",
  "pr_body": "GitHub-flavored markdown: a one-paragraph summary, a bullet list of the key changes, and a short 'Testing' note describing the tests added/run. No secrets."
}
```

Rules:

- The JSON must be valid and parseable. Output it last; put no prose after it.
- Ground every claim in the diff/spec — do not describe work that was not done.
- **Do not modify any files.** This step is read-only.
