# syntax=docker/dockerfile:1
#
# Always-containerized runtime (feature 031). One multi-stage Dockerfile:
#
#   base       OS, git, gh, Node (tool runtime for the agent CLI), the agent CLI,
#              non-root user. The release image is built from this later.
#   toolchain  base + build deps + mise + the repository's mise.toml toolchain.
#   dev        toolchain; source is bind-mounted at /workspace, not copied.
#   build      toolchain + the sources; compiles `mix release` (MIX_ENV=prod).
#   release    base + the release only: no mise, no Erlang/Elixir install, no
#              sources at runtime (FR-002). Started by `bin/autonomous start`.
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
# Opt-in testing capabilities (feature 031 US5/US6). Every block below is a no-op
# when its flag is not 1 (FR-023); set through `scripts/autonomous build --web ...`.
ARG WITH_WEB=0
ARG WITH_DESKTOP=0
ARG WITH_ANDROID=0
# Must match the @playwright/test version the target's tests use (docs/container.md).
ARG PLAYWRIGHT_VERSION=1.49.1
ARG ANDROID_CMDLINE_TOOLS=11076708
ARG ANDROID_SYSTEM_IMAGE=system-images;android-34;google_apis;x86_64
ARG ANDROID_PLATFORM=platforms;android-34

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

# ---- Opt-in: web testing (FR-024) -----------------------------------------------
# Three engines installed into a world-readable path; downloads are disabled at
# runtime so tests work offline and never write into $HOME.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    NODE_PATH=/usr/lib/node_modules
RUN if [ "$WITH_WEB" = 1 ]; then \
      mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
   && npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
   && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=0 playwright install --with-deps chromium firefox webkit \
   && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH" \
   && npm cache clean --force \
   && rm -rf /var/lib/apt/lists/*; \
    fi

# ---- Opt-in: desktop testing (FR-023, FR-025) -----------------------------------
# Virtual display + input/screenshot tools; the optional viewer (x11vnc + noVNC)
# is started by the entrypoint only when AUTONOMOUS_DISPLAY_VIEWER=1.
RUN if [ "$WITH_DESKTOP" = 1 ]; then \
      apt-get update \
   && apt-get install -y --no-install-recommends \
        xvfb xauth xdotool imagemagick x11vnc novnc websockify dbus-x11 \
        fonts-liberation fonts-noto-color-emoji \
        libnss3 libgtk-3-0 libasound2 libgbm1 libxss1 \
   && rm -rf /var/lib/apt/lists/*; \
    fi

# ---- Opt-in: Android testing (FR-026) --------------------------------------------
# JDK 17 + SDK tools + one pinned system image + an AVD created at build time.
# Writable by any uid: the container runs as the operator's host uid.
ENV ANDROID_HOME=/opt/android \
    ANDROID_SDK_ROOT=/opt/android \
    ANDROID_AVD_HOME=/opt/android/avd
RUN if [ "$WITH_ANDROID" = 1 ]; then \
      apt-get update \
   && apt-get install -y --no-install-recommends openjdk-17-jdk-headless unzip libpulse0 libnss3 libx11-6 libxcb1 \
   && rm -rf /var/lib/apt/lists/* \
   && mkdir -p "$ANDROID_HOME/cmdline-tools" "$ANDROID_AVD_HOME" \
   && curl -fsSL -o /tmp/cmdline-tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
   && unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
   && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
   && rm /tmp/cmdline-tools.zip \
   && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null \
   && "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platform-tools" "emulator" "${ANDROID_PLATFORM}" "${ANDROID_SYSTEM_IMAGE}" \
   && echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n autonomous -k "${ANDROID_SYSTEM_IMAGE}" --force \
   && chmod -R a+rwX "$ANDROID_HOME"; \
    fi
ENV PATH=${PATH}:/opt/android/cmdline-tools/latest/bin:/opt/android/platform-tools:/opt/android/emulator
COPY --chmod=0755 scripts/android-emulator /usr/local/bin/android-emulator

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

# ---------------------------------------------------------------------------
FROM toolchain AS build

ENV MIX_ENV=prod
WORKDIR /build

# Dependency layers first: cached until mix.exs / mix.lock / config change.
COPY --chown=autonomous mix.exs mix.lock ./
COPY --chown=autonomous config config
RUN mise exec -- mix deps.get --only prod \
 && mise exec -- mix deps.compile

COPY --chown=autonomous lib lib
COPY --chown=autonomous priv priv
COPY --chown=autonomous rel rel
RUN mise exec -- mix release autonomous --path /build/release

# ---------------------------------------------------------------------------
FROM base AS release

# The release bundles its ERTS; these are the shared libraries it links against
# (the base already carries libssl3 through curl, listed here to pin the intent).
RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 libncurses6 libssl3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build --chown=autonomous /build/release /app
COPY --chmod=0755 scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint.sh

USER autonomous
WORKDIR /app

# erlexec (the agent CLI transport) refuses to start without SHELL.
ENV SHELL=/bin/bash

ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
CMD ["release"]
