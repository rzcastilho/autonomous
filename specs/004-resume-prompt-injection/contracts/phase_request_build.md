# Contract: `PhaseRequest.build/3` with `:resume_prompt`

The internal interface this feature changes. `PhaseRequest.build/3` is a pure
function; this contract is exercised by unit tests (no CLI, no worktree).

## Signature (unchanged arity)

```elixir
@spec build(Feature.t(), atom(), keyword()) :: RunRequest.t()
def build(%Feature{} = feature, phase, opts \\ [])
```

## Opts

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `:cwd` | `String.t()` | `Config.repo()` | working directory (existing) |
| `:session_id` | `String.t() \| nil` | `nil` | resume Claude session (existing) |
| **`:resume_prompt`** | **`String.t() \| nil`** | **`nil`** | **NEW.** When non-blank, appended to `prompt` as a delimited trailing section. When blank (`nil`/`""`/whitespace-only), no effect. |

## Behavioral guarantees

### G1 — Append when non-blank (FR-001, FR-002)

Given any `phase` with a defined prompt and `opts[:resume_prompt] = "resolved: use integer cents"`,
the returned `RunRequest.prompt` MUST equal the base prompt for that phase followed by:

```
\n\n---\nOperator guidance (resume): resolved: use integer cents
```

i.e. `String.ends_with?(req.prompt, "\n\n---\nOperator guidance (resume): resolved: use integer cents")`
and the base prompt appears unchanged as the prefix.

### G2 — Byte-identical when blank (FR-003, SC-003)

For each of `resume_prompt ∈ {nil, "", "   ", "\n\t"}`, and for the opt being
absent entirely, `build/3` MUST return a `prompt` byte-identical to the prompt
built with no `:resume_prompt` opt at all. No marker line, no trailing
separator, no empty guidance body.

### G3 — Verbatim guidance (spec Assumptions)

The guidance text is included verbatim — no trimming of interior content, no
escaping, no truncation. (Leading/trailing whitespace only matters for the
blank check in G2; a non-blank string is appended as-is.)

### G4 — No other field changes (FR-007)

`model`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `max_turns`,
`cwd`, and `session_id` on the returned `RunRequest` MUST be identical whether or
not `:resume_prompt` is supplied. Only `prompt` may differ.

## Caller contract: `resume_prompt_for/2` (in `RunFeaturePhase`)

| Condition | `:resume_prompt` passed to `build/3` |
|-----------|--------------------------------------|
| `phase == state.resume_phase` | `state.resume_prompt` |
| `phase != state.resume_phase` | `nil` |
| fresh run (`state.resume_phase == nil`) | `nil` (no real phase atom equals `nil`) |

### G5 — Injected only at the resume phase (FR-004, FR-005, SC-001, SC-002)

Across a multi-phase run, the guidance section appears in exactly the built
prompt whose `phase == resume_phase`, and in no other phase's built prompt.

### G6 — Retry re-injects (FR-006, SC-004)

Repeated execution of the resume phase (before the pipeline advances) recomputes
a non-nil `:resume_prompt` each time; the guidance section is present on every
retry with no additional operator action.
