#!/bin/sh
# Container entrypoint (feature 031). Sequence: specs/031-containerized-runtime/
# contracts/compose-services.md. Identity is derived only in Elixir
# (`mix autonomous.instance`); this script never recomputes it.
#
#   dev image:     entrypoint <shell|console|test [mix test args]|segment|identity>
#   release image: entrypoint <release|segment|identity>
#
# The image decides the shape: the release image carries /app/bin/autonomous and
# no mise; the dev image is the opposite.
#
# Exit codes: 75 = target already served by another instance (lock held).
set -eu

cmd="${1:-shell}"
[ "$#" -gt 0 ] && shift

# erlexec aborts at app start when SHELL is unset (e.g. under `docker run`).
export SHELL="${SHELL:-/bin/sh}"

say() { printf 'autonomous: %s\n' "$*" >&2; }
warn() { printf 'autonomous: warning: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

: "${AUTONOMOUS_REPO:?AUTONOMOUS_REPO must be set (start through scripts/autonomous)}"
: "${AUTONOMOUS_ROOT:?AUTONOMOUS_ROOT must be set (start through scripts/autonomous)}"

# ---- 0. Dev shape: prepare the build ---------------------------------------
# Needs network (Hex, GitHub for the pinned jido_* SHAs). Runs before any
# orchestrated session exists, so the strict hook is not involved.
prepare_build() {
  cd /workspace
  lock_hash="$(sha256sum mix.lock | cut -d' ' -f1)"
  marker="deps/.autonomous_lock_hash"
  if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$lock_hash" ]; then
    mise exec -- mix deps.get || die "mix deps.get failed"
    printf '%s' "$lock_hash" > "$marker"
  fi
  mise exec -- mix compile || die "mix compile failed"
}

RELEASE_BIN="${AUTONOMOUS_RELEASE_BIN:-/app/bin/autonomous}"
if [ -x "$RELEASE_BIN" ]; then shape=release; else shape=dev; fi

case "$shape:$cmd" in
  dev:shell | dev:console | dev:segment | dev:identity) MIX_ENV=dev ;;
  dev:test) MIX_ENV=test ;;
  release:release | release:segment | release:identity) ;;
  dev:*) die "unknown command '$cmd' for the dev image (shell|console|test|segment|identity)" ;;
  release:*) die "unknown command '$cmd' for the release image (release|segment|identity)" ;;
esac

if [ "$shape" = dev ]; then
  export MIX_ENV
  # stdout stays clean: `segment`/`identity` are parsed by the wrapper.
  prepare_build >&2
fi

# `test` needs neither an identity nor the instance lock: it is the host suite
# (require_container is false in the test config) run inside the image.
if [ "$cmd" = "test" ]; then
  exec mise exec -- mix test "$@"
fi

# ---- 1. Derive the identity ---------------------------------------------------
# The derivation lives in Elixir only (Autonomous.Instance); dev asks the Mix
# task, the release evaluates the same function.
derive_identity() {
  if [ "$shape" = dev ]; then
    mise exec -- mix autonomous.instance --repo "$AUTONOMOUS_REPO" \
      --root "$AUTONOMOUS_ROOT" --format env | grep '^AUTONOMOUS_'
  else
    "$RELEASE_BIN" eval 'Autonomous.Instance.print_env()' | grep '^AUTONOMOUS_'
  fi
}

# A release evaluates runtime.exs even for `eval`, which refuses to run without
# a secret. Looking an identity up serves no HTTP, so give it a placeholder for
# that call only; `release` (which does serve) never gets one and refuses by name.
secret="${AUTONOMOUS_SECRET_KEY_BASE:-}"
if [ "$shape" = release ] && { [ "$cmd" = segment ] || [ "$cmd" = identity ]; } \
  && [ "${#secret}" -lt 64 ]; then
  AUTONOMOUS_SECRET_KEY_BASE="identity-lookup-only-$(printf '%064d' 0)"
  export AUTONOMOUS_SECRET_KEY_BASE
fi

identity="$(derive_identity)" \
  || die "could not derive the instance identity for $AUTONOMOUS_REPO"

if [ "$cmd" = "segment" ]; then
  # Used only by the wrapper to name the Compose project: no lock, no
  # instance.json, no VM.
  printf '%s\n' "$identity" | sed -n 's/^AUTONOMOUS_INSTANCE_SEGMENT=//p'
  exit 0
fi

if [ "$cmd" = "identity" ]; then
  # The wrapper reads segment and node name from here; it never derives them.
  printf '%s\n' "$identity"
  exit 0
fi

while IFS= read -r line; do
  [ -n "$line" ] && export "$line"
done <<EOF
$identity
EOF

# ---- 2. Take the per-target lock --------------------------------------------
instance_dir="$(dirname "$AUTONOMOUS_INSTANCE_LOCK")"
mkdir -p "$instance_dir"
exec 9>"$AUTONOMOUS_INSTANCE_LOCK"
if ! flock -n 9; then
  owner="$instance_dir/instance.json"
  detail="another instance"
  if [ -f "$owner" ]; then
    detail="$(python3 - "$owner" <<'PY' 2>/dev/null || echo "another instance"
import json, sys
o = json.load(open(sys.argv[1]))
print("%s/%s since %s" % (o.get("compose_project", "?"), o.get("service", "?"), o.get("started_at", "?")))
PY
)"
  fi
  say "target $AUTONOMOUS_REPO is already served by $detail"
  exit 75
fi

# ---- 3. Owner record and cookie ------------------------------------------------
python3 - "$instance_dir/instance.json" <<'PY'
import datetime, json, os, sys
port = os.environ.get("AUTONOMOUS_HOST_PORT") or None
record = {
    "segment": os.environ["AUTONOMOUS_INSTANCE_SEGMENT"],
    "repo": os.environ["AUTONOMOUS_REPO"],
    "compose_project": os.environ.get("COMPOSE_PROJECT_NAME", ""),
    "service": os.environ.get("AUTONOMOUS_SERVICE", ""),
    "started_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "console_port": int(port) if port else None,
    "image": os.environ.get("AUTONOMOUS_IMAGE", ""),
}
# Atomic: a second instance reading the owner record mid-write must never see a
# truncated file (the kernel lock, not this file, is authoritative).
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
os.replace(tmp, sys.argv[1])
PY

if [ ! -f "$AUTONOMOUS_COOKIE_PATH" ]; then
  (umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n=+/' > "$AUTONOMOUS_COOKIE_PATH")
fi
chmod 600 "$AUTONOMOUS_COOKIE_PATH"

# ---- 4. Git / gh credentials (FR-013, FR-014) ---------------------------------
# Remotes are often SSH; the container has no SSH key, so push over HTTPS.
git config --global url."https://github.com/".pushInsteadOf git@github.com:
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git || warn "gh auth setup-git failed; pushes may be rejected"
else
  warn "GH_TOKEN is not set; publishing (push + gh pr create) will fail"
fi

# ---- 5. Warnings (FR-016) --------------------------------------------------------
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
  && [ ! -e "$HOME/.claude.json" ]; then
  warn "no agent credentials: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN in .env, or start with --with-login"
fi
if [ -z "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ] || [ -z "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ]; then
  warn "ANTHROPIC_DEFAULT_OPUS_MODEL / ANTHROPIC_DEFAULT_SONNET_MODEL are unset; model aliases will not be pinned"
fi
warn_budget="${AUTONOMOUS_BUDGET_USD:-config default}"
say "budget is per instance (AUTONOMOUS_BUDGET_USD=$warn_budget); total spend is the sum across running instances"

say "instance $AUTONOMOUS_NODE_NAME serving $AUTONOMOUS_REPO"

# ---- 7. Hand over to the VM (fd 9 stays open: the lock lives as long as it does) --
export AUTONOMOUS_INSTANCE_LOCKED="$AUTONOMOUS_INSTANCE_LOCK"
cookie="$(cat "$AUTONOMOUS_COOKIE_PATH")"

case "$cmd" in
  shell)
    exec mise exec -- iex --sname "$AUTONOMOUS_NODE_NAME" --cookie "$cookie" -S mix
    ;;
  console)
    exec mise exec -- elixir --sname "$AUTONOMOUS_NODE_NAME" --cookie "$cookie" -S mix phx.server
    ;;
  release)
    # rel/env.sh.eex turns AUTONOMOUS_NODE_NAME / AUTONOMOUS_COOKIE_PATH into
    # RELEASE_NODE / RELEASE_COOKIE.
    exec "$RELEASE_BIN" start
    ;;
esac
