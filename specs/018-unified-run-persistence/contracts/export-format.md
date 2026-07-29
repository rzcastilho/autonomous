# Contract: Run Export Format

**Feature**: `018-unified-run-persistence` | **Requirements**: FR-032, FR-032a,
FR-032b, FR-032c, FR-029a, SC-016

## Shape

Exactly **one** file per run. Not a directory, not an archive, not a set of side
files (FR-032a). JSON, UTF-8, produced by `Store.Export.encode/1` (pure — takes
a loaded run detail plus its transcripts, returns iodata) and written by
`SpeckitOrchestrator.export_run/3`.

```json
{
  "format": "speckit.run-export",
  "format_version": 1,
  "exported_at": "2026-07-27T19:04:11.221Z",
  "producer": {"app": "speckit_orchestrator", "version": "0.1.0", "schema_version": 1},
  "repository": {"repo_id": "o:ledgerlite-9f3a1c", "origin": "github.com/rzcastilho/ledgerlite"},
  "run": {
    "run_id": "r000004",
    "state": "completed",
    "outcome": "escalated",
    "started_at": "…", "ended_at": "…", "duration_ms": 4821330,
    "spend_usd": 12.44,
    "record_complete": true,
    "halt_reason": null,
    "scope": {"breakdown": "ledgerlite"},
    "superseded_by": null,
    "settings": { "...the ten RunContext fields..." },
    "settings_amendments": [
      {"ordinal": 1, "changes": {"max_concurrency": [2, 3]},
       "effective_at": "…", "effective_after": "003:analyze:1"}
    ],
    "cost_entries": [
      {"attempt": "003:analyze:1", "amount_usd": 0.41, "kind": "actual", "recorded_at": "…"}
    ],
    "features": [
      {
        "feature_id": "003", "slug": "ledger-entries", "path": "…",
        "prereqs": ["001"], "status": "escalated",
        "terminal_reason": "analyze: High finding; auto-remediation exhausted (2/2)",
        "branch": "feature/003-ledger-entries", "worktree_path": null,
        "pr_description": null,
        "checkpoint": {"phase": "analyze", "last_completed_phase": "tasks",
                       "status": "escalated", "reason": "…",
                       "implement_chunk": null, "analyze_remediation": {"attempts_used": 2, "limit": 2}},
        "escalations": [
          {"ordinal": 1, "kind": "escalated", "phase": "analyze", "severity": "high",
           "reason": "…", "evidence": {"findings": []}, "raised_at": "…", "resolution": null}
        ],
        "remediation_attempts": [
          {"ordinal": 1, "findings": [], "max_severity": "high", "outcome": "ok",
           "cost_usd": 0.28, "attempt_limit": 2, "threshold": "high", "model": "opus",
           "attempt": "003:remediation:1"}
        ],
        "phase_attempts": [
          {
            "attempt": "003:analyze:1",
            "phase": "analyze", "ordinal": 1, "step": 5, "label": "analyze",
            "started_at": "…", "ended_at": "…", "duration_ms": 91223,
            "outcome": "ok", "model": "opus",
            "cost_usd": 0.41, "cost_kind": "actual",
            "substep": null, "session_id": "…", "error": null,
            "transcript": {"encoding": "utf8", "bytes": 18422, "written_at": "…",
                           "content": "# analyze\n\n- status: ok\n…"}
          }
        ]
      }
    ]
  }
}
```

## Rules

1. **Self-contained (FR-032b)** — no store path, worktree path, node name, or
   machine-local reference is required to read the file. `local_path` is never
   exported. `format_version` tells a reader what it is holding.
2. **Transcripts embedded as fields (FR-032a)** — on their phase attempt, never
   as side files.
3. **Verbatim (FR-029a)** — no redaction, scrubbing, filtering, or truncation,
   at write or at export. Because a transcript is raw tool output and need not
   be valid UTF-8 while a JSON string must be, each transcript declares an
   `"encoding"`:
   - `"utf8"` — `content` is the transcript text inline;
   - `"base64"` — `content` is the exact original bytes, base64-encoded.

   Base64 is a transport encoding, not a transformation of content: decoding it
   yields the stored bytes exactly. A reader that ignores `encoding` and treats
   everything as text is reading the file wrong, which is why the field is
   mandatory rather than optional.
4. **Attempt references** are the compact string `"<feature_id>:<phase>:<ordinal>"`,
   unique within the exported run and resolvable without the store.
5. **Read-only (FR-032c)** — export runs in a read-only transaction, takes no
   lock that blocks a writer, modifies nothing, prunes nothing, and is available
   while a run is in flight (exporting what is recorded so far) and while a
   capacity refusal is in effect.
6. **Timestamps** are ISO-8601 UTC strings. Ordering within the file follows the
   store's own ordering (attempts in execution order), so a reader never has to
   re-derive order from timestamps.

## Verification (SC-016)

A test exports a run, tears the store down entirely (fresh empty schema), and
reconstructs from the file alone: every feature, phase attempt, escalation,
remediation attempt, setting, cost entry, and transcript is recoverable, with
**zero** external references required. A round-trip property test asserts
transcript bytes are byte-identical after `encode → decode`, including a
non-UTF-8 fixture.
