This is the Spec Kit `analyze` step. It is **read-only** — do not modify any
files. Cross-check the spec, plan, and tasks against
`.specify/memory/constitution.md` and flag violations.

Check, at minimum, every checkable constitution MUST (e.g. monetary values as
integer cents, tests required per command, no network access, restricted exit
codes, deterministic output — whatever the constitution states).

After your analysis, end your response with **exactly one** JSON object on its
own, as the final content. It MUST match this schema:

```json
{
  "summary": "one-line overall assessment",
  "findings": [
    {
      "severity": "critical | high | medium | low",
      "title": "short title",
      "detail": "what is wrong and where",
      "constitution_rule": "the MUST it violates, or null"
    }
  ]
}
```

Rules:

- Use `"severity": "critical"` for any violation of a constitution MUST — these
  halt the feature.
- If there are no findings, emit `{"summary": "...", "findings": []}`.
- The JSON must be valid and parseable. Do not wrap prose around required fields.
- Output the JSON last; anything after it will be ignored.
