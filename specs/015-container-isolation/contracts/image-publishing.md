# Contract: Image Identity, Tagging, and Publishing

**Feature**: `015-container-isolation` | Satisfies FR-001, FR-005, FR-006,
FR-007, FR-008, FR-009, FR-010.

---

## 1. Build recipe (FR-001)

A single `Dockerfile` at the repository root produces a runnable image with no
manual step after the build command. The same recipe serves CI and a developer's
local build.

```bash
# local development build — identical recipe, no registry involved
docker build \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t autonomous:dev .
```

**Stages**

| Stage | Base (pinned by digest) | Produces |
|---|---|---|
| `builder` | `hexpm/elixir:1.20.2-erlang-<otp28.x>-debian-bookworm-<date>` | `MIX_ENV=prod mix release` output |
| `runtime` | `debian:bookworm-slim` | The runnable image |

Both stages MUST share the Debian release — ERTS is glibc-linked and a mismatch
produces a release that cannot boot.

**Runtime stage contains**: the release (`/app/bin/speckit_orchestrator` + ERTS +
`priv/`), the FR-002 tool set, `/etc/autonomous/image.json`, and the entrypoint.

**Runtime stage MUST NOT contain** (FR-003): orchestrator source, `mix`,
`rebar3`, Hex, `deps/`, `_build/`, or a standalone Elixir/Erlang installation.
A build-time assertion fails the build if `/app/lib/speckit_orchestrator-*/ebin`
is absent or if `mix` resolves on `PATH` in the runtime stage.

---

## 2. Build context exclusion (FR-006)

`.dockerignore` MUST exclude, at minimum:

```
_build/
deps/
cover/
doc/
.git/
.elixir_ls/
.DS_Store
tmp/
erl_crash.dump
*.ez
specs/
```

so image content is a function of committed source alone. `priv/` and `config/`
are **not** excluded — the release needs them.

---

## 3. Secrets (FR-005)

- No `ARG`/`ENV` in either stage carries a credential.
- No `COPY` brings in `.env`, `~/.claude`, `~/.gitconfig`, or any host-specific
  file.
- CI gates the push on `trivy image --scanners secret --exit-code 1` (SC-005).

---

## 4. Self-identification (FR-007)

**OCI labels** on the runtime stage:

| Label | Value |
|---|---|
| `org.opencontainers.image.source` | `https://github.com/rzcastilho/autonomous` |
| `org.opencontainers.image.revision` | full source SHA |
| `org.opencontainers.image.version` | `v<semver>` (or `dev` for a local build) |
| `org.opencontainers.image.created` | RFC3339 UTC |
| `org.opencontainers.image.title` | `autonomous` |

**In-container manifest** `/etc/autonomous/image.json`, world-readable, written
in the runtime stage from probed values — see
[`preflight-report.md` §1](./preflight-report.md#1-schema) for the `image` object
shape. Readable via `docker exec <name> cat /etc/autonomous/image.json` and
surfaced by `SpeckitOrchestrator.ImageInfo.read/0`.

---

## 5. Registry and tags (FR-008, FR-009, FR-010)

**Registry**: `ghcr.io/rzcastilho/autonomous`.

| Tag | Mutability | Purpose |
|---|---|---|
| `v<semver>` | **immutable** | The reproducible-run tag. One per release, never overwritten |
| `sha-<short-sha>` | **immutable** | Informational, one per built revision |
| `latest` | moving | Newest release. **Documented as unsuitable for reproducible runs** |

**Immutability enforcement**: before pushing, the workflow runs
`docker buildx imagetools inspect ghcr.io/rzcastilho/autonomous:v<semver>`. If it
resolves, the job **fails** — an existing version tag is never overwritten
(SC-010). The pushed digest is written to the job summary and to the GitHub
release notes so a run can pin `…@sha256:…`.

**Pull authentication** (FR-010): the normal operator path is
`docker pull ghcr.io/rzcastilho/autonomous:v<semver>`. Where the package is not
public, the operator supplies a registry credential at pull time
(`docker login ghcr.io`). No registry credential is baked into any image or
committed to the repository. Building locally from source remains available for
development only.

---

## 6. Publishing workflow (FR-008, SC-011)

`.github/workflows/image.yml` — the repository has no `.github/` today, so this
is new.

**Triggers**: push of a tag matching `v*`; `workflow_dispatch` with a `version`
input.

**Permissions**: `contents: read`, `packages: write` — authenticated by the
workflow's `GITHUB_TOKEN`; no operator-provisioned registry secret.

**Job steps**

1. Checkout at full depth (the source SHA becomes a label).
2. Derive `version` from the tag (or the dispatch input); reject a value that is
   not `v<semver>`.
3. **Immutability guard** — fail if `v<version>` already resolves in the registry.
4. Set up Buildx; log in to GHCR.
5. Build with `--build-arg SOURCE_REVISION`, `BUILT_AT`, `IMAGE_REF`, and the
   pinned tool-version args, using registry-backed layer caching.
6. **Secret scan** — `trivy image --scanners secret --exit-code 1`.
7. **Smoke test** — start the image with a fixture repo mount, assert preflight
   emits a report and `cat /etc/autonomous/image.json` matches the build args.
8. Push `v<semver>`, `sha-<short-sha>`, and `latest`.
9. Record the digest in the job summary.

Zero manual build-or-push steps: tagging a release is the only operator action
(SC-011).

---

## 7. Local build parity

The local build path uses the **same** `Dockerfile` with the same build args and
differs only in that it does not push, does not run the immutability guard, and
tags `autonomous:dev`. Documentation states plainly that `autonomous:dev` carries
no version identity and is not reproducible across machines (FR-036).
