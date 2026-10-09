# Contract: Container start — agent-root advertisement

Amends `specs/031-containerized-runtime/contracts/compose-services.md` (entrypoint
sequence) and `specs/036-container-workspace-trust/contracts/environment.md`.

## Step `agent_root` (entrypoint)

Position: after `4c. trust_workspaces`, before `5. Warnings`. Runs for every
instance command (`shell`, `console`, `release`); not for `segment`/`identity`/`test`.

```text
unset AUTONOMOUS_AGENT_ROOT
if sudo is on PATH:
    if `sudo -n true` exits 0:
        export AUTONOMOUS_AGENT_ROOT=1
        stderr: "autonomous: agent root: available (strict allows sudo apt-get/apt install)"
    else:
        stderr: "autonomous: warning: agent root built in but 'sudo -n true' failed for uid <uid>; not advertised"
else:
    (silent)
```

- A value supplied by `.env` or compose is never honoured (always unset first).
- Default image (no `sudo`): no output, no env change ⇒ start byte-identical.

## Smoke subcommand `agent-root`

`entrypoint agent-root` runs only the step above (no build, no identity, no lock)
and prints exactly one stdout line: `AUTONOMOUS_AGENT_ROOT=1` or `AUTONOMOUS_AGENT_ROOT=0`.
Exit 0 in both cases.

## Environment seen by the VM and sessions

| Var | Value | Set by |
|---|---|---|
| `AUTONOMOUS_CONTAINER` | `1` | image `ENV` (unchanged) |
| `AUTONOMOUS_AGENT_ROOT` | `1` or unset | this step |

Every orchestrated session additionally receives both (explicitly, on its launch
env) when — and only when — `AgentRoot.advertised?/0` is true (session-request.md).
