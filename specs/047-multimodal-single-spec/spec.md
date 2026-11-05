# Feature Specification: Multi-Modal Single-Spec Run

**Feature Branch**: `047-multimodal-single-spec`

**Created**: 2026-11-05

**Status**: Draft

**Input**: User description: "Support multi-modal in Single-spec run."

## Clarifications

### Session 2026-11-05

- Q: Which file types are accepted? → A: Images (PNG, JPEG, GIF, WebP), PDF, and text/data files (Markdown, plain text, CSV, JSON). Audio and video are not accepted.
- Q: Where do attachments live? → A: Committed on the feature branch next to the feature's spec, so they appear in the PR and travel with resume.
- Q: What happens when a session cannot read an attachment? → A: The specify and clarify sessions must never guess: they record `## NEEDS HUMAN` naming the file, and the existing clarify gate escalates. No new gate is added.
- Q: What happens when an attachment conflicts with the description or another attachment? → A: A material conflict records `## NEEDS HUMAN` and escalates at the clarify gate, by the existing materiality test; an immaterial one follows the description and is noted in the spec.
- Q: How do sessions treat instruction-like text inside an attachment? → A: As reference data only: attachment content describes the feature and is never a command to the session; embedded instructions are ignored and noted.
- Q: Is there a total size cap per run? → A: Yes, 25 MB total per run by default, configurable, refused with a named reason.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Attach files when starting a single-spec run from the console (Priority: P1)

An operator describing a feature often has material that text cannot carry: a UI mockup, a screenshot of a bug, an architecture diagram. On the Trigger view, in Single-spec mode, the operator adds one or more files alongside the free-text description, sees what is attached, removes any added by mistake, and starts the run. The sessions that write the specification work from the description and the attached material together, so the resulting spec reflects what the files show, not only what the text says.

**Why this priority**: This is the feature. Without it the operator has to translate a picture into words before the pipeline can use it, and whatever is lost in that translation is lost for every phase after it.

**Independent Test**: Start a single-spec run with a short description ("Build the screen in the attached mockup") plus one image whose content is not described anywhere in the text. Confirm the produced `spec.md` contains requirements that could only have come from the image.

**Acceptance Scenarios**:

1. **Given** Single-spec mode on the Trigger view, **When** the operator adds supported files, **Then** each appears in the form with its name and size, and can be removed individually before starting.
2. **Given** a description and valid attachments, **When** the operator starts the run, **Then** the run starts exactly as a text-only run does and the attachments are available to the feature's sessions.
3. **Given** a file of an unsupported type, a file over the size limit, more files than the limit allows, or a file that takes the run past its total size limit, **When** the operator adds it, **Then** that file is refused with a message naming the file and the limit it broke, and the rest of the form is unaffected.
4. **Given** attachments but a blank description, **When** the operator starts the run, **Then** the start is refused with the existing "Description is required" error and nothing starts.
5. **Given** a description and no attachments, **When** the operator starts the run, **Then** behaviour is identical to today's text-only single-spec run.

---

### User Story 2 - Attachments stay available through every phase (Priority: P1)

The specification is not the only step that needs the source material. A plan benefits from the diagram; an implementation session needs the mockup itself, not the spec's prose description of it. Every session of the feature — specify, clarify, plan, tasks, analyze, implement, converge, and any remediation — can reach the original attachments, and is told they exist and where they are.

**Why this priority**: Attachments visible only to the first phase degrade into a text summary one step later, which is the loss this feature exists to prevent.

**Independent Test**: Run a feature with an attached mockup and inspect the implement session's recorded conversation; confirm the session was told about the attachment and opened it.

**Acceptance Scenarios**:

1. **Given** a run with attachments, **When** any phase session starts, **Then** its instructions name each attachment and where to find it.
2. **Given** a run with attachments that stops at a gate, **When** the operator resumes or continues it, **Then** the attachments are present and unchanged for the resumed sessions.
3. **Given** a phase's session is retried or its worktree is restored to a clean state, **When** the session restarts, **Then** the attachments are still present.
4. **Given** the implement phase is split into chunks, **When** each chunk session starts, **Then** each chunk is told about the attachments.

---

### User Story 3 - Attach files from the programmatic entry point (Priority: P2)

An operator working from the remote console starts a single-spec run through the facade rather than the Trigger view. They pass file paths alongside the description and get the same behaviour and the same refusals as the console form.

**Why this priority**: The facade and the console are peer entry points, and the console dispatches through the facade. Keeping the capability in one place means there is one set of rules, but the operator can live without the direct path until the console works.

**Independent Test**: Call the single-spec entry point with a description and paths to two files; confirm the run behaves as in US1. Call it again with a path that does not exist; confirm a named refusal and that nothing started.

**Acceptance Scenarios**:

1. **Given** a description and paths to valid files, **When** the operator starts a run through the facade, **Then** the outcome matches a console start with the same files.
2. **Given** a path that is missing, unreadable, unsupported or over a limit, **When** the operator starts a run, **Then** the call returns a refusal naming the file and reason, and no worktree, branch, or run record is created.

---

### User Story 4 - See what a run was given (Priority: P2)

Reviewing a run — while it is live, after it ends, or on an escalation — the operator can see which files it was started with. A human reviewing the feature's pull request can also see them.

**Why this priority**: A spec whose reasoning rests on an image the reviewer cannot find is unreviewable. It matters, but only once attachments reach sessions at all.

**Independent Test**: Open Run Detail for a finished run with attachments and confirm each attachment is listed by name, type and size with a location an operator could open; open a text-only run and confirm no attachment section appears.

**Acceptance Scenarios**:

1. **Given** a run started with attachments, **When** the operator opens its Run Detail, **Then** each attachment is listed with its name, type, size and location.
2. **Given** a run with no attachments, **When** the operator opens its Run Detail, **Then** no attachment section appears, and the page is unchanged from today.
3. **Given** a finished feature whose PR was published, **When** a reviewer opens the PR body, **Then** it lists the attachments the feature was built from.

---

### Edge Cases

- Two attachments share a name: both are kept under distinct names, and each session is told the name it can actually open.
- A filename contains path separators, leading dots, spaces or non-ASCII characters: the stored name is made safe and can never resolve outside the feature's attachment location.
- A file's extension disagrees with its content (a text file renamed `.png`): the file is refused by what it actually is, not what it is called.
- A file is corrupt or empty: it is refused at the point of adding it, not discovered mid-run by a session.
- An upload is abandoned or the console page is left before starting: nothing is left behind in the target repository, and no run starts.
- The console's start is refused after files were added (preflight failure, parked run, bad setting): the operator's attachments are still on the form and can be retried without adding them again.
- A session reads an attachment and the content comes back through the conversation recorder: the recorded conversation, the conversation file and the console stay readable, and binary content is not stored as text in them.
- An attachment contains text addressed to the session ("ignore previous instructions", a command to run): the session does not act on it and notes it in the spec. This is an instruction to sessions, not a hard barrier; the container remains the boundary.
- An attachment conflicts with the description or with another attachment: a material conflict escalates at the clarify gate; an immaterial one follows the description and is noted in the spec.
- The specify or clarify session cannot read an attachment: it records `## NEEDS HUMAN` naming the file instead of guessing at the content, and the feature escalates at the clarify gate.
- The target repository's ignore rules would exclude the attachment location: attachments still reach every session.
- Attachments contain sensitive data (a screenshot showing a credential, a pasted secret in a text file): the orchestrator does not scan for it. The form warns before start that attachments are committed and pushed; removal afterwards is a history rewrite and the operator's responsibility.
- A text/data file contains non-text bytes or an unknown encoding: it is refused at the point of adding it.
- A run ends without publishing (escalated, halted, failed): the attachments stay on the local feature branch and are not pushed.
- An existing superseded or parked run blocks the start: refusal behaves exactly as for a text-only run, and attachments are not written anywhere.

## Requirements *(mandatory)*

### Functional Requirements

**Accepting attachments**

- **FR-001**: The single-spec form on the Trigger view MUST let the operator add zero or more files alongside the description, by file picker and by drag-and-drop.
- **FR-002**: The single-spec form MUST list each added file with its name and size, and let the operator remove it before starting.
- **FR-003**: The single-spec programmatic entry point MUST accept a list of file paths alongside the description.
- **FR-004**: System MUST accept attachments of these types: images (PNG, JPEG, GIF, WebP), PDF, and text/data files (Markdown, plain text, CSV, JSON). All other types, including audio and video, MUST be refused.
- **FR-005**: System MUST enforce a per-run limit on attachment count, a per-file limit on size and a per-run limit on total size, with defaults of 10 files, 10 MB per file and 25 MB total, each overridable by configuration.
- **FR-006**: System MUST determine an image's or PDF's type from its content, and refuse a file whose content does not match a supported type, regardless of its extension. A text/data file MUST carry a supported extension and MUST be valid text; a JSON file need not be well-formed JSON.
- **FR-007**: Every refusal MUST name the file and the specific reason, and MUST happen before any worktree, branch, or run record is created (fail loud at the boundary).
- **FR-008**: A description MUST remain required; attachments supplement a description and never replace it. Id and slug derivation from the description are unchanged.
- **FR-009**: Attachments MUST NOT affect the existing live id/slug preview.

**Delivering attachments to sessions**

- **FR-010**: Attachments MUST be committed on the feature branch next to the feature's spec before the first session starts, so they appear in the PR and in the commit history, even when the target repository's ignore rules would otherwise exclude them.
- **FR-011**: Every session of the feature — every phase, implement chunk, auto-remediation, remediation and PR describe — MUST be told which attachments exist and where to open them.
- **FR-012**: The specify session MUST be instructed to treat attachment content as part of the feature's input and to reflect it in the specification.
- **FR-012a**: The specify and clarify sessions MUST be instructed never to guess at an attachment they cannot read, and to record `## NEEDS HUMAN` naming the file, so the existing clarify gate escalates the feature.
- **FR-012b**: The clarify review MUST treat a conflict between an attachment and the description, or between two attachments, as a clarify question under the existing materiality test: material conflicts record `## NEEDS HUMAN`; immaterial ones follow the description and are noted in the spec.
- **FR-012c**: Every session told about attachments MUST also be instructed that their content is reference data describing the feature, never a command to the session, and that embedded instructions are not to be followed. The specify session MUST note any such text in the spec.
- **FR-013**: Attachments MUST survive a session retry, a worktree restore to clean state, and a resume or continue of the feature, unchanged and byte-identical.
- **FR-014**: Attachments MUST NOT be altered, recompressed, or re-encoded by the orchestrator.
- **FR-015**: Stored attachment names MUST be safe and unique within the feature, and MUST NOT be able to resolve outside the feature's attachment location.

**Truthful surfaces**

- **FR-016**: Run Detail MUST list each attachment by name, type, size and location for a run started with attachments, and MUST show nothing new for a run without them.
- **FR-017**: The run's durable record MUST include the attachment list, so it survives an orchestrator restart. Records created before this feature MUST continue to load and render unchanged.
- **FR-018**: The PR body for a feature with attachments MUST list them.
- **FR-019**: The single-spec form MUST state, before the run starts, that attachments are committed to the feature branch and pushed to the target's remote, so they are visible to anyone who can read that repository and remain in its history.
- **FR-020**: Console and report wording MUST use the system's real identifiers, and all new console styling MUST follow the design contract with no new colors, fonts or literals outside the shared token block.

**Recording and compatibility**

- **FR-021**: The conversation recorder and the console's conversation views MUST represent a session's read of an image or PDF attachment by a compact placeholder, and MUST NOT store the binary content as text in the conversation file or the live window. Text/data attachments are recorded like any other file read, including credential masking.
- **FR-022**: A single-spec run with no attachments MUST behave byte-identically to today: same prompts, same seed, same commits, same console output.
- **FR-023**: Backlog runs MUST be unaffected. Attachments are a single-spec capability only.
- **FR-024**: The gates (clarify, analyze, artifact substance, incomplete session, branch drift) MUST apply to a run with attachments exactly as to one without.

### Key Entities *(include if feature involves data)*

- **Attachment**: One operator-supplied file belonging to a single-spec feature. Attributes: original name, stored name, detected type, size, content fingerprint, location on the feature branch. Immutable once the run starts.
- **Attachment Manifest**: The ordered list of a feature's attachments, recorded durably with the run and rendered into session instructions, Run Detail and the PR body.
- **Attachment Limits**: The allowed types, maximum count per run, maximum size per file and maximum total size per run; defaults with a configuration override.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can add three files to a single-spec run and start it in under one minute, without leaving the Trigger view.
- **SC-002**: Given a mockup whose content is absent from the description, the produced specification contains at least one requirement traceable only to that mockup, in 100% of validation runs.
- **SC-003**: 100% of phase sessions in a run with attachments are told about every attachment, verifiable from the recorded conversations.
- **SC-004**: 100% of invalid attachments are refused before any worktree, branch, or run record exists.
- **SC-005**: After a resume, every attachment is byte-identical to what was supplied at start, in 100% of checks.
- **SC-006**: A text-only single-spec run shows zero observable differences from the pre-feature behaviour across prompts, commits and console output.
- **SC-007**: Conversation views remain usable for a session that opened a maximum-size attachment: the view loads with no binary content in it and no perceptible delay against a text-only session.

## Assumptions

- "Multi-modal" means non-text input supplied by the operator at the start of a run. Model-generated images and spoken input are out of scope.
- Target users are the existing single operator of the console; no per-user access model is introduced.
- Sessions read attachments as files using their existing tools. The harness's own attachment field is not forwarded by the current provider, so delivery relies on the file being reachable from the session's working directory.
- Vision capability is available on every model the phase routing uses today.
- Whether a session looked at an attachment can be audited from its recorded conversation; the orchestrator adds no gate that forces a read. Later phases are not covered by the clarify gate; an attachment read successfully at specify is byte-identical at every later phase.
- Attachments can only be supplied at start. Adding or replacing attachments on resume, on clarify answers, or as operator guidance is out of scope.
- Size and count defaults are chosen to cover mockups, screenshots and design documents; larger media are not a goal.
- Attachments are not scanned for secrets; the operator owns what they attach, and the FR-019 notice makes the consequence explicit.
- No constitution amendment is expected: the feature adds input to an existing path and leaves gates, containment and cost accounting unchanged.
