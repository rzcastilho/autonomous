#!/bin/sh
# Container smoke checks (feature 031). Run by hand from the repository root; not
# part of the default test suite. Each check prints PASS/FAIL/SKIP; exit 1 on any
# FAIL. Sections are added per user story — see
# specs/031-containerized-runtime/quickstart.md.
#
#   scripts/container-smoke.sh [us1|us2|us3|us4]
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

# ---- helpers shared by the instance-level sections (US2+) ---------------------------

# Directories to remove on exit. A file, because make_target runs in a subshell.
smoke_list="$(mktemp)"
cleanup() {
  while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d"; done <"$smoke_list"
  rm -f "$smoke_list"
}
trap cleanup EXIT

# A throwaway target: a git repo with an `origin`, so its identity is remote-derived.
make_target() { # make_target <name> -> prints path
  d="$(mktemp -d)/$1"
  mkdir -p "$d"
  dirname "$d" >>"$smoke_list"
  git -C "$d" init -q -b main
  git -C "$d" -c user.name=smoke -c user.email=smoke@example.com commit -q --allow-empty -m init
  git -C "$d" remote add origin "https://example.invalid/smoke/$1.git"
  printf '%s\n' "$d"
}

# Feed one-line Elixir statements to the operator shell of a target (no TTY).
# iex needs a terminal to read statements, so the wrapper runs under `script` (a PTY),
# fed through a FIFO. Input is held back until the banner appears (`docker run -t`
# flushes anything typed while the image compiles and the VM boots) and dropped
# when the session dies first (e.g. exit 75), so a refused start never hangs.
pty_feed() { # pty_feed <wrapper args> <outfile> <code> [hold]
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  timeout 1000 script -qec "scripts/autonomous $1" /dev/null <"$fifo" >"$2" 2>&1 &
  spid=$!
  exec 8>"$fifo"
  waited=0
  until grep -q 'Interactive Elixir' "$2" 2>/dev/null || ! kill -0 "$spid" 2>/dev/null || [ "$waited" -ge 900 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$spid" 2>/dev/null; then
    sleep 2
    printf '%s\n' "$3" >&8
  fi
  # A remote console does not end on EOF: give the output a moment, then end it.
  if [ -n "${PTY_LINGER:-}" ] && kill -0 "$spid" 2>/dev/null; then
    sleep "$PTY_LINGER"
    kill "$spid" 2>/dev/null
  fi
  # Closing the FIFO ends the session; a holder keeps it open until it exits.
  [ -n "${4:-}" ] && wait "$spid" 2>/dev/null
  exec 8>&-
  wait "$spid" 2>/dev/null
  rm -f "$fifo"
}

iex_feed() { # iex_feed <target> <port> <outfile> <code> [hold]
  pty_feed "shell --target $1 --port $2" "$3" "$4" "${5:-}"
}

iex_eval() { # iex_eval <target> <port> <code>
  out="$(mktemp)"
  iex_feed "$1" "$2" "$out" "$(printf '%s\n:init.stop()' "$3")"
  tr -d '\r' <"$out"
  rm -f "$out"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

instance_dir_of() { # instance_dir_of <target> -> state dir for its segment
  seg="$(AUTONOMOUS_REPO="$1" AUTONOMOUS_ROOT="$HOME/.autonomous" \
    mise exec -- mix autonomous.instance --repo "$1" --root "$HOME/.autonomous" --format segment 2>/dev/null)"
  printf '%s/.autonomous/instances/%s\n' "$HOME" "$seg"
}

purge_target() { # purge_target <target>: remove containers, volumes and state of a smoke target
  scripts/autonomous stop --target "$1" --purge >/dev/null 2>&1 || true
  rm -rf "$(instance_dir_of "$1")"
}

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

us2() {
  echo "== US2: run state survives container restarts and recreation =="

  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { fail "image $IMAGE exists (run scripts/autonomous build)"; return; }

  # FR-018: every service pins the host part of the node name.
  hostnames="$(AUTONOMOUS_REPO=/tmp AUTONOMOUS_ROOT=/tmp AUTONOMOUS_UID=1000 AUTONOMOUS_GID=1000 \
    docker compose config --format json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["services"]; print(all(v.get("hostname")=="autonomous" for v in d.values()), ",".join(sorted(d)))')"
  case "$hostnames" in
    True*) pass "every compose service sets hostname: autonomous (${hostnames#True })" ;;
    *) fail "every compose service sets hostname: autonomous ($hostnames)" ;;
  esac

  a="$(make_target smoke-a)"
  b="$(make_target smoke-b)"
  seg_a="$(basename "$(instance_dir_of "$a")")"
  port_a="$(free_port)"

  # SC-005: a run record written by one container is listed by the recreated one.
  write='repo = Autonomous.RepoIdentity.partition(Autonomous.Config.repo()); {:ok, id} = Autonomous.Store.Writer.open_run(repo, %{features: [%{feature_id: "001", slug: "smoke", path: "docs/breakdown/001-smoke.md", number: 1, group: :backlog, created_at: nil}], settings: %{}, scope: :ad_hoc, layout: %{}}); :ok = Autonomous.Store.Writer.close_run(Autonomous.Store.Ids.run_key(repo, id), :all_done); IO.puts("SMOKE-RUN " <> id)'
  out1="$(iex_eval "$a" "$port_a" "$write")"
  run_id="$(printf '%s\n' "$out1" | sed -n 's/^SMOKE-RUN \(r[0-9]*\).*/\1/p' | head -n1)"
  if [ -n "$run_id" ]; then pass "first container wrote run $run_id"; else fail "first container wrote a run record: $out1"; return; fi

  # Recreate from the (re)built image: --rm already removed the first container.
  list='{:ok, runs} = Autonomous.run_history(); IO.puts("SMOKE-IDS " <> Enum.map_join(runs, ",", & &1.run_id)); IO.puts("SMOKE-NODE " <> to_string(node()))'
  out2="$(iex_eval "$a" "$port_a" "$list")"
  if printf '%s' "$out2" | grep -q 'schema_node_mismatch'; then
    fail "recreated container boots without schema_node_mismatch"
  else
    pass "recreated container boots without schema_node_mismatch"
  fi
  if printf '%s' "$out2" | grep '^SMOKE-IDS' | grep -q "$run_id"; then
    pass "recreated container lists the run written before recreation"
  else
    fail "recreated container lists run $run_id: $out2"
  fi
  node1="$(printf '%s\n' "$out1" | sed -n 's/^SMOKE-NODE //p' | head -n1)"
  node2="$(printf '%s\n' "$out2" | sed -n 's/^SMOKE-NODE //p' | head -n1)"
  if [ -n "$node2" ] && { [ -z "$node1" ] || [ "$node1" = "$node2" ]; }; then
    pass "node name is stable across recreation ($node2)"
  else
    fail "node name is stable across recreation ($node1 vs $node2)"
  fi

  # FR-018a: a second instance for the same target is refused (75), naming the live one.
  hold="$(mktemp -d)"
  printf "%s\n" "$hold" >>"$smoke_list"
  port_hold="$(free_port)"
  iex_feed "$a" "$port_hold" "$hold/out" 'IO.puts("SMOKE-HELD"); Process.sleep(120_000)' hold &
  holder=$!
  waited=0
  until grep -q SMOKE-HELD "$hold/out" 2>/dev/null || [ "$waited" -ge 120 ]; do sleep 1; waited=$((waited + 1)); done
  if grep -q SMOKE-HELD "$hold/out" 2>/dev/null; then
    second="$(scripts/autonomous shell --target "$a" --port "$(free_port)" </dev/null 2>&1)"
    rc=$?
    if [ "$rc" -eq 75 ] && printf '%s' "$second" | grep -q "already served by"; then
      pass "second instance for the same target exits 75 naming the live instance"
    else
      fail "second instance for the same target exits 75 (rc=$rc): $second"
    fi

    # SC-007a: a different target runs concurrently, on a different port.
    other="$(iex_eval "$b" "$(free_port)" 'IO.puts("SMOKE-NODE " <> to_string(node()))')"
    if printf '%s' "$other" | grep -q 'SMOKE-NODE autonomous_smoke-b'; then
      pass "a different target runs concurrently with its own node"
    else
      fail "a different target runs concurrently: $other"
    fi
  else
    fail "first holder instance became ready: $(cat "$hold/out" 2>/dev/null)"
  fi
  kill "$holder" 2>/dev/null || true
  held="$(docker ps -q --filter "label=com.docker.compose.project=autonomous-$seg_a")"
  [ -n "$held" ] && docker kill $held >/dev/null 2>&1
  waited=0
  while [ -n "$(docker ps -q --filter "label=com.docker.compose.project=autonomous-$seg_a")" ] && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done

  # SC-006: worktrees created through the container are valid from the host.
  wt_cmd='repo = Autonomous.Config.repo(); root = Path.join(Autonomous.Config.autonomous_root(), "worktrees/smoke-wt"); File.mkdir_p!(root); {_, 0} = System.cmd("git", ["-C", repo, "worktree", "add", "-b", "smoke/wt", Path.join(root, "wt")]); IO.puts("SMOKE-WT " <> Path.join(root, "wt"))'
  out3="$(iex_eval "$a" "$(free_port)" "$wt_cmd")"
  wt="$(printf '%s\n' "$out3" | sed -n 's/^SMOKE-WT //p' | head -n1)"
  if [ -n "$wt" ] && git -C "$a" worktree list --porcelain | grep -q "worktree $wt" \
    && ! git -C "$a" worktree list --porcelain | grep -q prunable; then
    pass "container-created worktree is valid from the host (git worktree list, not prunable)"
  else
    fail "container-created worktree is valid from the host: $out3"
  fi
  rm -rf "$HOME/.autonomous/worktrees/smoke-wt"

  purge_target "$a"
  purge_target "$b"
}

http_ok() { # http_ok <port>: the console answers (any HTTP status counts)
  python3 -c '
import sys, urllib.request
try:
    urllib.request.urlopen("http://127.0.0.1:%s/" % sys.argv[1], timeout=5)
except Exception as e:
    sys.exit(0 if hasattr(e, "code") else 1)
' "$1"
}

us3() {
  echo "== US3: operator watches the run from the web console =="

  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { fail "image $IMAGE exists (run scripts/autonomous build)"; return; }

  t="$(make_target smoke-console)"
  p="$(free_port)"

  out="$(scripts/autonomous console --target "$t" --port "$p" </dev/null 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "console  http://127.0.0.1:$p/"; then
    pass "console starts detached and prints its loopback address"
  else
    fail "console starts detached (rc=$rc): $out"
    purge_target "$t"
    return
  fi

  check "console answers on the printed address" http_ok "$p"

  # FR-021: published on loopback only, never on every interface.
  seg_t="$(basename "$(instance_dir_of "$t")")"
  cid="$(docker ps -q --filter "label=com.docker.compose.project=autonomous-$seg_t" | head -n1)"
  binding="$(docker port "$cid" 4000/tcp 2>/dev/null | head -n1)"
  case "$binding" in
    127.0.0.1:"$p") pass "published binding is 127.0.0.1:$p (not 0.0.0.0)" ;;
    *) fail "published binding is 127.0.0.1:$p (got: ${binding:-none})" ;;
  esac

  shown="$(scripts/autonomous port --target "$t" 2>&1)"
  case "$shown" in
    *"http://127.0.0.1:$p/"*) pass "port prints the running instance's address" ;;
    *) fail "port prints the running instance's address: $shown" ;;
  esac

  # SC-007: a busy requested port is refused with 76, naming the port.
  holder_port="$(free_port)"
  python3 -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(60)
' "$holder_port" &
  holder=$!
  sleep 1
  busy="$(scripts/autonomous console --target "$(make_target smoke-console-busy)" --port "$holder_port" </dev/null 2>&1)"
  rc=$?
  if [ "$rc" -eq 76 ] && printf '%s' "$busy" | grep -q "console port $holder_port is already in use on 127.0.0.1"; then
    pass "busy --port exits 76 naming the port"
  else
    fail "busy --port exits 76 (rc=$rc): $busy"
  fi
  kill "$holder" 2>/dev/null || true

  # A second start for the same target is refused (75) while the console runs.
  again="$(scripts/autonomous console --target "$t" --port "$(free_port)" </dev/null 2>&1)"
  rc=$?
  if [ "$rc" -eq 75 ] || printf '%s' "$again" | grep -q 'already served'; then
    pass "second console start for the same target is refused (75)"
  else
    fail "second console start for the same target is refused (rc=$rc): $again"
  fi

  echo "NOTE  second-machine reachability (SC-007) stays manual: see quickstart.md section 4"

  purge_target "$t"
}

RELEASE_IMAGE="autonomous-release:local"

us4() {
  echo "== US4: self-contained release image =="

  docker image inspect "$RELEASE_IMAGE" >/dev/null 2>&1 \
    || { fail "image $RELEASE_IMAGE exists (run scripts/autonomous build --release)"; return; }
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { fail "image $IMAGE exists (run scripts/autonomous build)"; return; }

  # FR-002: no build toolchain at runtime.
  absent="$(docker run --rm --entrypoint sh "$RELEASE_IMAGE" -c \
    'for b in mise mix elixir; do command -v $b >/dev/null 2>&1 && echo "$b"; done; test -d /workspace && echo workspace; find /app /opt -name "*.ex" 2>/dev/null | head -n1')"
  if [ -z "$absent" ]; then pass "release image has no mise/mix/elixir and no sources"; else fail "release image has no toolchain: $absent"; fi

  t="$(make_target smoke-release)"
  p="$(free_port)"
  state="$(mktemp -d)"
  printf '%s\n' "$state" >>"$smoke_list"

  # FR-022: without a secret the release refuses, naming the variable. Run the
  # image directly so a secret in the operator's .env cannot leak into the check.
  out="$(docker run --rm --hostname autonomous --user "$(id -u):$(id -g)" \
    -e AUTONOMOUS_REPO="$t" -e AUTONOMOUS_ROOT="$state" -v "$t:$t" -v "$state:$state" \
    "$RELEASE_IMAGE" release 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AUTONOMOUS_SECRET_KEY_BASE'; then
    pass "release refuses without AUTONOMOUS_SECRET_KEY_BASE, naming it"
  else
    fail "release refuses without AUTONOMOUS_SECRET_KEY_BASE (rc=$rc): $out"
  fi

  if [ -z "$(command -v openssl)" ]; then fail "openssl available to generate a secret"; return; fi
  AUTONOMOUS_SECRET_KEY_BASE="$(openssl rand -base64 48)"
  export AUTONOMOUS_SECRET_KEY_BASE

  out="$(scripts/autonomous release --target "$t" --port "$p" </dev/null 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "console ready at http://127.0.0.1:$p/"; then
    pass "release starts detached and serves the console"
  else
    fail "release starts detached and serves the console (rc=$rc): $out"
    unset AUTONOMOUS_SECRET_KEY_BASE
    purge_target "$t"
    return
  fi
  check "release console answers on the printed address" http_ok "$p"

  # SC-008: remote console attaches, a record written through it survives a restart.
  write='repo = Autonomous.RepoIdentity.partition(Autonomous.Config.repo()); {:ok, id} = Autonomous.Store.Writer.open_run(repo, %{features: [%{feature_id: "001", slug: "smoke", path: "docs/breakdown/001-smoke.md", number: 1, group: :backlog, created_at: nil}], settings: %{}, scope: :ad_hoc, layout: %{}}); :ok = Autonomous.Store.Writer.close_run(Autonomous.Store.Ids.run_key(repo, id), :all_done); IO.puts("SMOKE-RUN " <> id <> " " <> to_string(node()))'
  out="$(remote_eval "$t" "$write")"
  line="$(printf '%s\n' "$out" | sed -n 's/^SMOKE-RUN //p' | head -n1)"
  run_id="${line%% *}"
  case "$line" in
    r[0-9]*" autonomous_smoke-release"*) pass "remote console attaches to the release node ($line)" ;;
    *) fail "remote console attaches to the release node: $out" ;;
  esac

  seg="$(basename "$(instance_dir_of "$t")")"
  AUTONOMOUS_REPO="$t" AUTONOMOUS_ROOT="$HOME/.autonomous" AUTONOMOUS_UID="$(id -u)" AUTONOMOUS_GID="$(id -g)" \
    AUTONOMOUS_HOST_PORT="$p" docker compose -p "autonomous-$seg" -f compose.yaml restart release >/dev/null 2>&1
  waited=0
  until http_ok "$p" || [ "$waited" -ge 300 ]; do sleep 2; waited=$((waited + 2)); done
  if http_ok "$p"; then pass "release serves the console again after a restart"; else fail "release serves the console again after a restart"; fi

  out="$(remote_eval "$t" '{:ok, runs} = Autonomous.run_history(); IO.puts("SMOKE-IDS " <> Enum.map_join(runs, ",", & &1.run_id))')"
  if [ -n "$run_id" ] && printf '%s\n' "$out" | grep '^SMOKE-IDS' | grep -q "$run_id"; then
    pass "history survives a restart with no node mismatch"
  else
    fail "history survives a restart (run $run_id): $out"
  fi

  unset AUTONOMOUS_SECRET_KEY_BASE
  purge_target "$t"
}

remote_eval() { # remote_eval <target> <code>
  out="$(mktemp)"
  PTY_LINGER=5 pty_feed "remote --target $1" "$out" "$2"
  tr -d '\r' <"$out"
  rm -f "$out"
}

section="${1:-all}"
case "$section" in
  us1) us1 ;;
  us2) us2 ;;
  us3) us3 ;;
  us4) us4 ;;
  all) us1; us2; us3; us4 ;;
  *) echo "usage: scripts/container-smoke.sh [us1|us2|us3|us4]" >&2; exit 2 ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "smoke: all checks passed"; else echo "smoke: $fails check(s) FAILED"; exit 1; fi
