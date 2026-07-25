#!/usr/bin/env bash
#
# Launcher for the containerized orchestrator (contracts/container-run.md §1).
# Derives every mount and path-identity assertion from HOST values so the two
# `-v` flags and the two AUTONOMOUS_HOST_* assertions can never drift apart
# (FR-018/FR-019) — the operator never hand-writes a container path.
#
# Usage:
#   autonomous-container.sh start --env-file <path> [--autostart <slug|ad-hoc>]
#                                  [--image <ref>] [--name <name>] [--port <port>]
#   autonomous-container.sh stop [--name <name>] [--timeout <seconds>]

set -euo pipefail

NAME="autonomous"
IMAGE="${AUTONOMOUS_IMAGE:-ghcr.io/rzcastilho/autonomous:latest}"
STOP_TIMEOUT=900
ENV_FILE=""
AUTOSTART=""
PORT_OVERRIDE=""

usage() {
  cat >&2 <<'USAGE'
Usage:
  autonomous-container.sh start --env-file <path> [--autostart <slug|ad-hoc>]
                                 [--image <ref>] [--name <name>] [--port <port>]
  autonomous-container.sh stop [--name <name>] [--timeout <seconds>]
USAGE
  exit 1
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --autostart)
      AUTOSTART="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    --port)
      PORT_OVERRIDE="$2"
      shift 2
      ;;
    --timeout)
      STOP_TIMEOUT="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

# Last matching KEY=... line in ENV_FILE, quotes stripped. Empty if absent.
env_value() {
  local key="$1"
  [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

case "$COMMAND" in
  start)
    [ -n "$ENV_FILE" ] || {
      echo "start requires --env-file <path>" >&2
      usage
    }
    [ -f "$ENV_FILE" ] || {
      echo "env file not found: $ENV_FILE" >&2
      exit 1
    }

    # REPO comes from SPECKIT_REPO in the env file — never a separate flag —
    # so it is structurally impossible for the -v mount and the
    # AUTONOMOUS_HOST_REPO assertion to name different paths.
    REPO="$(env_value SPECKIT_REPO)"
    [ -n "$REPO" ] || {
      echo "SPECKIT_REPO is not set in $ENV_FILE" >&2
      exit 1
    }

    PORT="${PORT_OVERRIDE:-$(env_value AUTONOMOUS_CONSOLE_PORT)}"
    PORT="${PORT:-4000}"

    mkdir -p "$HOME/.autonomous"

    # Credential path B (contracts/environment.md §4) — only mounted if the
    # operator has an authenticated ~/.claude; path A (ANTHROPIC_API_KEY in
    # the env file) needs no mount at all.
    claude_mount=()
    if [ -d "$HOME/.claude" ]; then
      claude_mount=(-v "$HOME/.claude:/run/secrets/claude:ro")
    fi

    autostart_env=()
    if [ -n "$AUTOSTART" ]; then
      autostart_env=(-e "AUTONOMOUS_AUTOSTART=$AUTOSTART")
    fi

    exec docker run -d --name "$NAME" \
      --user "$(id -u):$(id -g)" \
      --read-only \
      --cap-drop ALL \
      --security-opt no-new-privileges \
      --pids-limit 4096 \
      --stop-timeout "$STOP_TIMEOUT" \
      --tmpfs /tmp:rw,nosuid,nodev,size=1g \
      --tmpfs "$HOME:rw,nosuid,nodev,mode=0700,uid=$(id -u),gid=$(id -g)" \
      -v "$REPO:$REPO" \
      -v "$HOME/.autonomous:$HOME/.autonomous" \
      "${claude_mount[@]+"${claude_mount[@]}"}" \
      -p "127.0.0.1:${PORT}:${PORT}" \
      --env-file "$ENV_FILE" \
      -e HOME="$HOME" \
      -e AUTONOMOUS_HOST_REPO="$REPO" \
      -e AUTONOMOUS_HOST_HOME="$HOME" \
      -e AUTONOMOUS_CONSOLE_PORT="$PORT" \
      -e RELEASE_COOKIE="$(head -c 32 /dev/urandom | base64)" \
      "${autostart_env[@]+"${autostart_env[@]}"}" \
      "$IMAGE"
    ;;

  stop)
    # Prefer a console/remote-console-driven drain over this hard stop where
    # possible (docs/runbook.md) — --stop-timeout gives Coordinator/Ledger
    # room to flush before the engine sends SIGKILL (FR-027).
    exec docker stop --timeout "$STOP_TIMEOUT" "$NAME"
    ;;

  *)
    usage
    ;;
esac
