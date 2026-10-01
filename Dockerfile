# syntax=docker/dockerfile:1
#
# Always-containerized runtime (feature 031). One multi-stage Dockerfile:
#
#   base       OS, git, gh, Node (tool runtime for the agent CLI), the agent CLI,
#              non-root user. The release image is built from this later.
#   toolchain  base + build deps + mise + the repository's mise.toml toolchain.
#   dev        toolchain; source is bind-mounted at /workspace, not copied.
#
# Erlang/Elixir versions are NOT restated here (FR-010): `mise install` reads
# mise.toml, the single version source. No secret is a build arg or ENV (FR-015).

ARG DEBIAN_TAG=bookworm-slim

# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS base

ARG UID=1000
ARG GID=1000
ARG GH_VERSION=2.102.0
ARG NODE_MAJOR=22
ARG CLAUDE_CODE_VERSION=2.1.286

ENV DEBIAN_FRONTEND=noninteractive \
    AUTONOMOUS_CONTAINER=1 \
    AUTONOMOUS_CONSOLE_IP=0.0.0.0 \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client python3 util-linux procps \
 && rm -rf /var/lib/apt/lists/*

# Node.js: runtime for the coding-agent CLI only (no console build step).
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# gh, pinned, from the official release tarball.
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
      | tar -xz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
 && rm -rf "/tmp/gh_${GH_VERSION}_linux_${arch}"

# The coding-agent CLI, pinned (FR-011). Resolves on PATH for every user.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# Non-root user with the host's ids so bind-mounted files stay owned by the
# operator (FR-006). Reuse a pre-existing group with the requested gid.
RUN (getent group "${GID}" >/dev/null || groupadd -g "${GID}" autonomous) \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash autonomous

# The only repositories in the container are the ones deliberately mounted, and
# their owner is the host operator (FR-008).
RUN git config --system safe.directory '*'

# ---------------------------------------------------------------------------
FROM base AS toolchain

ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_YES=1 \
    MISE_TRUSTED_CONFIG_PATHS=/workspace:/build \
    MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex \
    PATH=/opt/mise/shims:${PATH}

# Erlang is compiled from source by mise; these are its documented build deps.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential autoconf m4 libncurses-dev libssl-dev libssh-dev \
      unixodbc-dev xsltproc fop libxml2-utils unzip \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN mkdir -p /opt/mise /opt/mix /opt/hex /build \
 && chown -R autonomous: /opt/mise /opt/mix /opt/hex /build

USER autonomous
WORKDIR /build

# Cached layer keyed on mise.toml alone.
COPY --chown=autonomous mise.toml ./mise.toml
RUN mise install \
 && mise exec -- mix local.hex --force \
 && mise exec -- mix local.rebar --force

# ---------------------------------------------------------------------------
FROM toolchain AS dev

# Source is bind-mounted at /workspace; _build and deps are per-project named
# volumes (compose.yaml), so host- and container-compiled artefacts never mix.
USER root
RUN mkdir -p /workspace/_build /workspace/deps \
 && chown -R autonomous: /workspace
USER autonomous
WORKDIR /workspace

# erlexec (the agent CLI transport) refuses to start without SHELL.
ENV SHELL=/bin/bash

ENTRYPOINT ["/workspace/scripts/container-entrypoint.sh"]
CMD ["shell"]
