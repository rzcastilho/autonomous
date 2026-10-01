#!/bin/sh
# Container smoke checks (feature 031). Run by hand from the repository root; not
# part of the default test suite. Each check prints PASS/FAIL/SKIP; exit 1 on any
# FAIL. Sections are added per user story — see
# specs/031-containerized-runtime/quickstart.md.
#
#   scripts/container-smoke.sh [us1]
#
# Needs: Docker Engine + Compose v2, the image built (scripts/autonomous build).
# Agent-auth checks (SC-011) spend a few cents and run only with SMOKE_AGENT=1.
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

IMAGE="autonomous-dev:local"
fails=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; }

check() { # check <description> <command...>
  desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

in_image() { docker run --rm --user "$(id -u):$(id -g)" --entrypoint sh "$IMAGE" -c "$1"; }

us1() {
  echo "== US1: operator runs the orchestrator only inside a container =="

  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { fail "image $IMAGE exists (run scripts/autonomous build)"; return; }

  # SC-003: a host start is refused, and nothing is written to the state root.
  tmp_root="$(mktemp -d)"
  out="$(AUTONOMOUS_ROOT="$tmp_root" mise exec -- mix run -e ':ok' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refuses to start outside its container'; then
    pass "host start is refused with the contract message"
  else
    fail "host start is refused with the contract message (rc=$rc)"
  fi
  if [ -z "$(ls -A "$tmp_root")" ]; then
    pass "refused host start wrote no instances/ or mnesia"
  else
    fail "refused host start wrote into the state root: $(ls "$tmp_root")"
  fi
  rm -rf "$tmp_root"

  # SC-002/SC-003: compile and test still run on the host.
  check "host mix compile works" mise exec -- mix compile
  check "host mix test works (guard/instance tests)" \
    mise exec -- mix test test/autonomous/container_guard_test.exs test/autonomous/instance_test.exs

  # SC-002: the same suite passes inside the image.
  check "in-container mix test passes" \
    scripts/autonomous test test/autonomous/container_guard_test.exs test/autonomous/instance_test.exs

  # FR-011: the agent CLI is on PATH for the container user and inside the VM.
  check "claude --version resolves as the container user" in_image 'claude --version'
  vm="$(docker run --rm --user "$(id -u):$(id -g)" -w /build --entrypoint mise "$IMAGE" \
    exec -- elixir -e 'IO.puts(System.find_executable("claude") || "MISSING")' 2>/dev/null | tail -n1)"
  case "$vm" in
    '' | MISSING) fail "System.find_executable(\"claude\") is non-nil inside the VM" ;;
    *) pass "System.find_executable(\"claude\") is non-nil inside the VM ($vm)" ;;
  esac

  # FR-009: an orchestrated strict session is denied an out-of-tree write, naming
  # the profile and the rule. Runs the real hook inside the image.
  denial="$(docker run --rm --user "$(id -u):$(id -g)" \
    -v "$root/priv/target_pack/.claude/hooks:/hooks:ro" \
    -e AUTONOMOUS_ORCHESTRATED=1 -e AUTONOMOUS_CONTAINMENT_PROFILE=strict \
    --entrypoint sh "$IMAGE" -c \
    'echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/etc/passwd\"},\"cwd\":\"/tmp/wt\"}" | python3 /hooks/scope_guard.py' 2>&1)"
  if printf '%s' "$denial" | grep -q '"permissionDecision": *"deny"' \
    && printf '%s' "$denial" | grep -qi 'strict' && printf '%s' "$denial" | grep -qi 'outside worktree'; then
    pass "strict orchestrated session is denied an out-of-tree write (profile and rule named)"
  else
    fail "strict orchestrated session is denied an out-of-tree write: $denial"
  fi

  # SC-011 / FR-012: agent auth sources. Spends money, so opt-in.
  if [ "${SMOKE_AGENT:-0}" = 1 ]; then
    prompt='reply with the single word ok'
    if [ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      check "claude -p succeeds with a token only" \
        docker run --rm --user "$(id -u):$(id -g)" -e ANTHROPIC_API_KEY -e CLAUDE_CODE_OAUTH_TOKEN \
        --entrypoint claude "$IMAGE" -p "$prompt"
    else
      skip "token-only auth (no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN in this environment)"
    fi
    if [ -d "$HOME/.claude" ] && [ -f "$HOME/.claude.json" ]; then
      check "claude -p succeeds with the mounted login only" \
        docker run --rm --user "$(id -u):$(id -g)" \
        -v "$HOME/.claude:/home/autonomous/.claude" -v "$HOME/.claude.json:/home/autonomous/.claude.json" \
        --entrypoint claude "$IMAGE" -p "$prompt"
    else
      skip "login-only auth (no host ~/.claude login)"
    fi
    skip "both present: the CLI-reported auth source is the token (inspect 'claude auth status' by hand)"
  else
    skip "agent auth checks (set SMOKE_AGENT=1 to run; each spends a few cents)"
  fi
}

section="${1:-all}"
case "$section" in
  us1 | all) us1 ;;
  *) echo "usage: scripts/container-smoke.sh [us1]" >&2; exit 2 ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "smoke: all checks passed"; else echo "smoke: $fails check(s) FAILED"; exit 1; fi
