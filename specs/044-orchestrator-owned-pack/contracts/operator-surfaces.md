# Contract: Operator surfaces (044)

## Console — Configuration page

New row in the instance `<dl>`, next to "agent root" (`config_live.ex:256`), always
rendered (unlike agent root, it has no `:hidden` state):

| `PackView.state/1` | `<dt>` | `<dd data-pack-source="…">` text |
|---|---|---|
| `{:supplied, 6}` | `target pack` | `supplied by the orchestrator — contract 6` |
| `{:committed, n}` | `target pack` | `committed in the target — contract n` |
| `{:refused, text}` | `target pack` | refusal via `.form_refusal` with `text` (from `Report.format_reason/1`) |

- `data-pack-source` = `supplied | committed | refused` (a name, never a value — G rules).
- Values are mono (`config-instance-id` class), as the agent-root row.
- Computed in a `Task` on connected mount / refresh (`TargetPack.source(Config.repo())`),
  initial assign `:loading` renders `checking…`; a failed task renders `{:refused, …}`
  with the failure, never a crash. No `inspect/1` in markup (G-inspect).
- Design guard (`design_contract_test.exs`) must stay clean: no new tokens, no inline style.

## `Report.format_reason/1` — new clauses

| Reason | Text |
|---|---|
| `{:pack_local_tracked, rel, hint}` | `"#{rel} is tracked: #{hint}"` |
| `{:invalid_settings, rel}` | `"#{rel} is not a JSON object — fix or remove it, commit, and re-run"` |
| `{:pack_supply, reason}` | `"could not supply the target pack: " <> format_reason(reason)` |

`{:pack_outdated, rel, hint}` keeps its existing rendering; only the hint changes.

## Docs

- `docs/enforcement.md` § Target pack: orchestrator-supplied is the default; the
  install step leaves the operator's checklist; "Reinstalling an outdated pack" gains the
  remove-from-VCS remedy; compatibility table for the three target states.
- `docs/runbook.md`: target setup no longer commits the pack; refusal messages and
  remedies; Configuration "target pack" row.
- `docs/container.md`: wherever "committed target pack" is said, say "target pack
  (supplied into each worktree, or committed)".
- `CLAUDE.md`: Enforcement paragraph rewritten (supply/1, settings.local.json, shared
  exclude, verify no longer requires the files); new "Orchestrator-owned pack (feature
  044)" section.
