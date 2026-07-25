# syntax=docker/dockerfile:1
#
# Container Isolation for Autonomous Runs (specs/015-container-isolation).
# Two-stage build: `builder` produces an ERTS-embedded `mix release`;
# `runtime` carries only that release plus the pipeline's external tools —
# no orchestrator source, no mix/Hex/rebar3, no standalone Elixir/Erlang
# install (FR-003). Both stages share the Debian release (bookworm) — ERTS
# is glibc-linked and a mismatch produces a release that will not boot
# (research.md §R2).
#
# Local development build (no registry, no push):
#   docker build --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
#     --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -t autonomous:dev .
# `autonomous:dev` carries no version identity and is not reproducible across
# machines (FR-036, contracts/image-publishing.md §7) — only a `v<semver>`
# tag built via .github/workflows/image.yml is.

ARG ELIXIR_BASE=hexpm/elixir:1.20.2-erlang-28.5.0.3-debian-bookworm-20260713@sha256:5ddc090d8db7b7f54b64228a238952280266463016211ee86518a361c08f3864
ARG RUNTIME_BASE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

# ===========================================================================
# Stage: builder
# ===========================================================================
FROM ${ELIXIR_BASE} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

# git — jido_harness/jido_claude are GitHub-SHA-pinned deps (mix.exs), fetched
# by `mix deps.get` below, not from Hex. build-essential — erlexec (a
# transitive dep pulled in by the harness tree) compiles a NIF/port at
# `mix deps.compile` time; this toolchain never reaches the runtime stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Deps first so the layer cache survives source-only changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile
RUN mix release

# The release must exist before the runtime stage bothers copying it.
RUN test -d /app/_build/${MIX_ENV}/rel/speckit_orchestrator/lib/speckit_orchestrator-*/ebin

# ===========================================================================
# Stage: runtime
# ===========================================================================
FROM ${RUNTIME_BASE} AS runtime

ARG ELIXIR_BASE
ARG RUNTIME_BASE
ARG SOURCE_REVISION=unknown
ARG BUILT_AT=unknown
ARG IMAGE_REF=autonomous:dev
ARG GH_VERSION=2.96.0
ARG CLAUDE_CODE_VERSION=stable
ARG SPECKIT_VERSION=v0.12.11
ARG UV_VERSION=0.11.32
ARG MISE_VERSION=v2026.7.13

LABEL org.opencontainers.image.source="https://github.com/rzcastilho/autonomous" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.version="${IMAGE_REF}" \
      org.opencontainers.image.created="${BUILT_AT}" \
      org.opencontainers.image.title="autonomous"

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    # erlexec (a transitive dep used to run subprocesses) hard-crashes the
    # whole release at boot ("port_exited_with_status 4") if $SHELL is unset —
    # discovered smoke-testing this image under the real --user/--read-only
    # isolation flags, where no login shell sets it for you.
    SHELL=/bin/bash

# git (System.cmd call sites in lib/), python3 (the scope-guard hook is
# invoked as `python3`), ca-certificates/curl (tool installers below),
# bash (.specify/scripts/bash/*.sh), coreutils' `timeout` (the adapter's
# command template) ships in bookworm-slim's base already.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      python3-minimal \
      ca-certificates \
      curl \
      bash \
    && rm -rf /var/lib/apt/lists/*

# gh (GitHub CLI) — official release tarball, checksum-verified (research.md §R3).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) ghArch=amd64 ;; \
      arm64) ghArch=arm64 ;; \
      *) echo "unsupported architecture for gh: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ghArch}.tar.gz"; \
    curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"; \
    sha256sum --ignore-missing -c gh_${GH_VERSION}_checksums.txt; \
    tar -xzf "gh_${GH_VERSION}_linux_${ghArch}.tar.gz"; \
    install -m 0755 "gh_${GH_VERSION}_linux_${ghArch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh_*

# uv — static binary, checksum-verified. Installer for `specify` below.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) uvArch=x86_64-unknown-linux-gnu ;; \
      arm64) uvArch=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture for uv: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uvArch}.tar.gz"; \
    curl -fsSLO "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uvArch}.tar.gz.sha256"; \
    sha256sum -c "uv-${uvArch}.tar.gz.sha256"; \
    tar -xzf "uv-${uvArch}.tar.gz"; \
    install -m 0755 "uv-${uvArch}/uv" /usr/local/bin/uv; \
    rm -rf /tmp/uv-*

# mise — static binary, checksum-verified (target-toolchain resolution, FR-004).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) miseArch=x64 ;; \
      arm64) miseArch=arm64 ;; \
      *) echo "unsupported architecture for mise: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${miseArch}.tar.gz"; \
    curl -fsSLO "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/SHASUMS256.txt"; \
    grep "\./mise-${MISE_VERSION}-linux-${miseArch}.tar.gz\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xzf "mise-${MISE_VERSION}-linux-${miseArch}.tar.gz"; \
    install -m 0755 "mise/bin/mise" /usr/local/bin/mise; \
    rm -rf /tmp/mise*

# specify (Spec Kit CLI) — pinned tag via uv, used by the pack bootstrap/
# upgrade path (docs/enforcement.md), not the run loop (research.md §R3 note).
RUN uv tool install --python python3 \
      "specify-cli @ git+https://github.com/github/spec-kit.git@${SPECKIT_VERSION}"
ENV PATH="/root/.local/bin:${PATH}"

# claude (Claude Code CLI) — native installer, pinned version.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}"
ENV PATH="/root/.local/bin:${PATH}"

# FR-003: no build tooling leaked into the runtime stage.
RUN ! command -v mix >/dev/null 2>&1

# The release — no orchestrator source, no _build/, no deps/.
COPY --from=builder /app/_build/prod/rel/speckit_orchestrator /app
RUN test -d /app/lib/speckit_orchestrator-*/ebin

# In-container self-identification (FR-007): world-readable, probed from the
# tools actually installed above plus the build args, read by
# SpeckitOrchestrator.ImageInfo.read/0 and surfaced in the preflight report.
RUN set -eux; \
    mkdir -p /etc/autonomous; \
    git_v="$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    gh_v="$(gh --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    py_v="$(python3 --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    mise_v="$(mise --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    uv_v="$(uv --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    claude_v="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
    claude_v="${claude_v:-unknown}"; \
    builder_digest="${ELIXIR_BASE#*@}"; \
    runtime_digest="${RUNTIME_BASE#*@}"; \
    printf '%s\n' \
      '{' \
      "  \"source_revision\": \"${SOURCE_REVISION}\"," \
      '  "orchestrator_version": "0.1.0",' \
      "  \"image_ref\": \"${IMAGE_REF}\"," \
      "  \"built_at\": \"${BUILT_AT}\"," \
      '  "elixir": "1.20.2",' \
      '  "otp": "28",' \
      '  "base_digests": {' \
      "    \"builder\": \"${builder_digest}\"," \
      "    \"runtime\": \"${runtime_digest}\"" \
      '  },' \
      '  "tools": {' \
      "    \"git\": \"${git_v}\"," \
      "    \"gh\": \"${gh_v}\"," \
      "    \"claude\": \"${claude_v}\"," \
      "    \"specify\": \"${SPECKIT_VERSION}\"," \
      "    \"python3\": \"${py_v}\"," \
      "    \"mise\": \"${mise_v}\"," \
      "    \"uv\": \"${uv_v}\"" \
      '  }' \
      '}' \
      > /etc/autonomous/image.json; \
    chmod 0644 /etc/autonomous/image.json

# Entrypoint (research.md §R4/§R5/§R7/§R11): copies a read-only-mounted
# credential path B config into the ephemeral $HOME (no host write-back),
# sets git trust + identity plumbing for a bind-mounted, host-owned repo with
# no home-directory git config, points mise's data/cache at the durable
# run-state mount, then execs the release in the foreground so SIGTERM
# reaches it directly.
COPY <<'ENTRYPOINT_EOF' /usr/local/bin/docker-entrypoint.sh
#!/bin/sh
set -eu

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0='*'

export MISE_DATA_DIR="${HOME}/.autonomous/mise/data"
export MISE_CACHE_DIR="${HOME}/.autonomous/mise/cache"
export MISE_TRUSTED_CONFIG_PATHS="${SPECKIT_REPO:-}"
export MISE_YES=1

if [ -d /run/secrets/claude ]; then
  mkdir -p "${HOME}/.claude"
  cp -r /run/secrets/claude/. "${HOME}/.claude/"
  export CLAUDE_CONFIG_DIR="${HOME}/.claude"
fi

exec /app/bin/speckit_orchestrator start
ENTRYPOINT_EOF
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
