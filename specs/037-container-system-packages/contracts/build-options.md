# Contract: Image build options (`scripts/autonomous build`)

Amends `specs/031-containerized-runtime/contracts/wrapper-cli.md` (build command only).

## Synopsis

```text
scripts/autonomous build [--release] [--web] [--desktop] [--android]
                         [--apt "<pkg> [<pkg>…]"]… [--agent-root]
```

| Option | Build arg (compose `dev` + `release`) | Default |
|---|---|---|
| `--apt <list>` (repeatable, accumulates; whitespace/comma separated) | `EXTRA_APT_PACKAGES` | `""` |
| `--agent-root` | `WITH_AGENT_ROOT` | `0` |

Both options are accepted **only** with `build`; on any other command they are
`unknown option` (exit 2), matching how the wrapper treats misplaced options today.
`--android` keeps its existing dual meaning (build arg / start-time KVM).

## Validation (before any `docker` call)

- Each token MUST match `^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+)?$`.
- First failing token ⇒ stderr `autonomous: invalid package name '<token>'`, exit **2**.
- `--apt ""` (empty after split) ⇒ treated as no packages.

## Dockerfile behaviour (`base` stage, after the Android block)

1. `EXTRA_APT_PACKAGES` non-empty ⇒ `apt-get update`, `apt-get install -y
   --no-install-recommends $EXTRA_APT_PACKAGES`, write `/etc/autonomous/apt-packages`
   (one name per line), clean lists. Install failure fails the build; the apt
   error names the package (FR-003). Empty ⇒ no-op.
2. `WITH_AGENT_ROOT=1` ⇒ install `sudo`; write `/etc/sudoers.d/autonomous-agent-root`
   (`0440`, validated with `visudo -cf`) and `/etc/apt/apt.conf.d/99autonomous-no-remove`
   (see data-model.md). `0` ⇒ no-op; no `sudo` binary (FR-006).

Both images (`dev` via `toolchain`, `release`) inherit from `base`, so one
`build --release --apt … --agent-root` applies to both (FR-001).

## Compose

`compose.yaml` `dev.build.args` and `release.build.args` add:

```yaml
EXTRA_APT_PACKAGES: "${EXTRA_APT_PACKAGES:-}"
WITH_AGENT_ROOT: "${WITH_AGENT_ROOT:-0}"
```

No runtime `environment:` entry is added: `AUTONOMOUS_AGENT_ROOT` is decided by
the entrypoint only (container-start.md).

## Invariants

- No option given ⇒ every new block is a no-op; no file added to the image (FR-002, SC-004).
- The usage text lists both options.
