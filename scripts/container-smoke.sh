#!/bin/sh
# Container smoke checks (feature 031). Run by hand from the repository root; not
# part of the default test suite. Each check prints PASS/FAIL/SKIP; exit 1 on any
# FAIL. Sections are added per user story — see
# specs/031-containerized-runtime/quickstart.md.
#
#   scripts/container-smoke.sh [us1|us2|us3|us4|us5|us6|secrets|trust|us-trust-hook|sysdeps]
#
# Needs: Docker Engine + Compose v2, the image built (scripts/autonomous build).
# Agent-auth checks (SC-011) spend a few cents and run only with SMOKE_AGENT=1.
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

IMAGE="${SMOKE_IMAGE:-autonomous-dev:local}"
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

  # Feature 034 (US2): --with-login seeds a private ~/.claude.json from a
  # read-only seed mount. No spend; runs the real entrypoint's seed-config step.
  seed_dir="$(mktemp -d)"
  printf '{"smoke":true}\n' > "$seed_dir/valid.json"
  printf '{' > "$seed_dir/invalid.json"
  seed_run() { # seed_run <seed file> <cmd...>: run in the image with HOME=/home/autonomous
    sf="$1"
    shift
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/seedhome \
      -v "$root/scripts/container-entrypoint.sh:/ep.sh:ro" \
      -v "$sf:/home/autonomous/.claude.host.json:ro" \
      --entrypoint sh "$IMAGE" -c "mkdir -p /tmp/seedhome && $*"
  }
  check "valid seed -> ~/.claude.json is a regular file, not a mount, byte-equal to the seed" \
    seed_run "$seed_dir/valid.json" \
    'sh /ep.sh seed-config && [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ] && ! grep -q " $HOME/.claude.json " /proc/self/mountinfo && cmp "$HOME/.claude.json" /home/autonomous/.claude.host.json'
  inv="$(seed_run "$seed_dir/invalid.json" 'sh /ep.sh seed-config' 2>&1)"
  inv_rc=$?
  if [ "$inv_rc" -ne 0 ] && printf '%s' "$inv" | grep -q '/home/autonomous/.claude.host.json'; then
    pass "invalid seed -> entrypoint exits non-zero naming the seed path"
  else
    fail "invalid seed -> entrypoint exits non-zero naming the seed path (rc=$inv_rc): $inv"
  fi
  rm -rf "$seed_dir"

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
        -v "$HOME/.claude:/home/autonomous/.claude" \
        -v "$HOME/.claude.json:/home/autonomous/.claude.host.json:ro" \
        -v "$root/scripts/container-entrypoint.sh:/ep.sh:ro" \
        --entrypoint sh "$IMAGE" -c 'sh /ep.sh seed-config && exec claude -p "$1"' sh "$prompt"
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

# ---- US5 / US6: opt-in testing capabilities (SC-009, FR-023) -------------------------
# These build their own throwaway tags (never autonomous-dev:local), so the
# default image is not replaced. `us5` downloads three browser engines and is slow
# on a cold cache; `us6` downloads the Android SDK and one system image (GBs).
build_caps() { # build_caps <tag> <build args...>
  tag="$1"
  shift
  docker build -q --target dev -t "$tag" "$@" . >/dev/null 2>&1
}

us5() {
  echo "== US5: web and desktop capabilities"
  off=autonomous-smoke-off:local
  on=autonomous-smoke-webdesktop:local

  if build_caps "$off"; then pass "image builds with no capability options"; else fail "image builds with no capability options"; return; fi
  for bin in xvfb-run xdotool x11vnc import; do
    if docker run --rm --entrypoint sh "$off" -c "command -v $bin" >/dev/null 2>&1; then
      fail "default image has no $bin"
    else
      pass "default image has no $bin"
    fi
  done
  if docker run --rm --entrypoint sh "$off" -c 'ls /opt/ms-playwright/* >/dev/null 2>&1 || command -v emulator >/dev/null 2>&1'; then
    fail "default image has no browsers and no emulator"
  else
    pass "default image has no browsers and no emulator"
  fi

  if build_caps "$on" --build-arg WITH_WEB=1 --build-arg WITH_DESKTOP=1; then
    pass "image builds with --web --desktop"
  else
    fail "image builds with --web --desktop"
    return
  fi

  # Offline: --network none proves no download is attempted. Run as the operator's
  # uid, the way a session runs. chromiumSandbox:false needs no extra privilege.
  js='const pw=require("playwright");(async()=>{for(const [n,t] of [["chromium",pw.chromium],["firefox",pw.firefox],["webkit",pw.webkit]]){const b=await t.launch(n==="chromium"?{chromiumSandbox:false}:{});const p=await b.newPage();await p.setContent("<title>ok</title>");if(await p.title()!=="ok")process.exit(1);await b.close();console.log("ENGINE-OK "+n);}})().catch(e=>{console.error(e);process.exit(1)})'
  out="$(docker run --rm --network none --shm-size=1gb --user "$(id -u):$(id -g)" -e HOME=/tmp --entrypoint node "$on" -e "$js" 2>&1)"
  for engine in chromium firefox webkit; do
    case "$out" in
      *"ENGINE-OK $engine"*) pass "playwright $engine runs a page offline" ;;
      *) fail "playwright $engine runs a page offline: $(printf '%s' "$out" | tail -n2)" ;;
    esac
  done

  out="$(docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp --entrypoint sh "$on" -c \
    'xvfb-run -a sh -c "xdotool mousemove 10 10 click 1 && import -window root /tmp/shot.png" && test -s /tmp/shot.png && echo SHOT-OK' 2>&1)"
  case "$out" in
    *SHOT-OK*) pass "desktop: click + screenshot written under a virtual display" ;;
    *) fail "desktop: click + screenshot written: $(printf '%s' "$out" | tail -n2)" ;;
  esac

  # A strict orchestrated session is allowed to run those commands (hook matrix).
  hook=priv/target_pack/.claude/hooks/scope_guard.py
  verdict="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"npx playwright test 2>/dev/null"},"cwd":"/tmp/wt"}' \
    | AUTONOMOUS_ORCHESTRATED=1 AUTONOMOUS_CONTAINMENT_PROFILE=strict python3 "$hook")"
  if [ -z "$verdict" ]; then pass "strict hook allows the device-sink redirect"; else fail "strict hook allows the device-sink redirect: $verdict"; fi
}

us6() {
  echo "== US6: Android capability"
  img=autonomous-smoke-android:local
  if build_caps "$img" --build-arg WITH_ANDROID=1; then pass "image builds with --android"; else fail "image builds with --android"; return; fi

  run_emu() { docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp "$@" --entrypoint android-emulator "$img"; }

  # Neither kvm nor a host adb: the message names both options.
  out="$(run_emu 2>&1)"; code=$?
  if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -qi 'in-container emulator' && printf '%s' "$out" | grep -qi 'host adb'; then
    pass "no device: non-zero exit naming the emulator and host-adb options"
  else
    fail "no device: expected non-zero exit naming both options (exit $code): $out"
  fi

  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    if run_emu --device /dev/kvm --group-add "$(stat -c '%g' /dev/kvm)" >/dev/null 2>&1; then
      pass "emulator boots with /dev/kvm"
    else
      fail "emulator boots with /dev/kvm"
    fi
  else
    skip "emulator boot (no usable /dev/kvm on this host)"
  fi

  if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | sed 1d | grep -q 'device$'; then
    if run_emu --add-host host.docker.internal:host-gateway -e ADB_SERVER_SOCKET=tcp:host.docker.internal:5037 >/dev/null 2>&1; then
      pass "host adb fallback reaches the host device"
    else
      fail "host adb fallback reaches the host device (run 'adb -a nodaemon server' on the host)"
    fi
  else
    skip "host adb fallback (no host adb with an attached device)"
  fi
}

secrets() {
  echo "== Secrets: image layers, saved image and tracked files hold no operator secret"
  # Candidate values: local .env plus the credential variables of this shell. Never printed.
  vals="$(mktemp)"
  {
    [ -f .env ] && sed -n 's/^[A-Za-z_][A-Za-z0-9_]*=//p' .env
    printf '%s\n' "${ANTHROPIC_API_KEY:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}"
  } | sed -e 's/^["'\'']//' -e 's/["'\'']$//' | awk 'length($0) >= 8' | sort -u >"$vals"
  if [ ! -s "$vals" ]; then
    skip "secret scan (no .env values or credential variables of length >= 8 to look for)"
    rm -f "$vals"
    return
  fi
  pass "scanning for $(wc -l <"$vals" | tr -d ' ') candidate secret value(s)"

  if docker history --no-trunc "$IMAGE" 2>/dev/null | grep -qFf "$vals"; then
    fail "docker history --no-trunc leaks a secret value"
  else
    pass "docker history --no-trunc is clean"
  fi

  saved="$(mktemp -d)"
  if docker save "$IMAGE" 2>/dev/null | tar -x -C "$saved" 2>/dev/null; then
    if grep -rqFf "$vals" "$saved" 2>/dev/null; then
      fail "saved image layers leak a secret value"
    else
      pass "saved image layers are clean"
    fi
  else
    fail "docker save $IMAGE"
  fi
  rm -rf "$saved"

  if git grep -qFf "$vals" -- . ':!.env' 2>/dev/null; then
    fail "tracked files leak a secret value (git grep)"
  else
    pass "tracked files are clean (git grep)"
  fi
  rm -f "$vals"
}

# Feature 036: container workspace trust. Runs the real entrypoint's trust-config
# step in the image against throwaway HOMEs. No spend except the SMOKE_AGENT check.
trust() {
  echo "== Trust: the container trusts exactly the repo and worktree root (feature 036)"
  td="$(mktemp -d)"
  echo "$td" >>"$smoke_list"
  printf '{"smoke":true,"projects":{"/third/path":{"hasTrustDialogAccepted":true,"allowedTools":["Bash"]}}}\n' >"$td/seed.json"
  printf '{' >"$td/invalid.json"
  host_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
  trust_run() { # trust_run <seed file> <cmd...>: HOME=/tmp/th, repo /tmp/r, root /tmp/wt
    sf="$1"
    shift
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/th \
      -e AUTONOMOUS_REPO=/tmp/r -e AUTONOMOUS_WORKTREE_ROOT=/tmp/wt \
      -v "$root/scripts/container-entrypoint.sh:/ep.sh:ro" \
      -v "$sf:/home/autonomous/.claude.host.json:ro" \
      --entrypoint sh "$IMAGE" -c "mkdir -p /tmp/th /tmp/r && $*"
  }
  dump='python3 -c "import json,os;c=json.load(open(os.environ[\"HOME\"]+\"/.claude.json\"));print(sorted(c[\"projects\"]))"'

  before="$(host_sha "$td/seed.json")"
  out="$(trust_run "$td/seed.json" "sh /ep.sh trust-config && $dump" 2>/dev/null | tail -1)"
  if [ "$out" = "['/third/path', '/tmp/r', '/tmp/wt']" ]; then
    pass "exact trusted set: the seeded path plus repo and worktree root, no ancestors"
  else
    fail "exact trusted set (got: $out)"
  fi
  [ "$before" = "$(host_sha "$td/seed.json")" ] \
    && pass "host seed file sha256 unchanged" || fail "host seed file sha256 unchanged"

  check "seeded keys preserved (smoke, third-path allowedTools)" \
    trust_run "$td/seed.json" \
    'sh /ep.sh trust-config && python3 -c "import json,os;c=json.load(open(os.environ[\"HOME\"]+\"/.claude.json\"));assert c[\"smoke\"] is True and c[\"projects\"][\"/third/path\"][\"allowedTools\"]==[\"Bash\"]"'

  for n in 1 2 5; do
    check "idempotent across $n run(s): bytes identical after the first" \
      trust_run "$td/seed.json" \
      "sh /ep.sh trust-config && h=\$(sha256sum \"\$HOME/.claude.json\") && i=1 && while [ \$i -lt $n ]; do rm -f /tmp/nope; sh /ep.sh trust-config; i=\$((i+1)); done && [ \"\$h\" = \"\$(sha256sum \"\$HOME/.claude.json\")\" ]"
  done

  # An invalid config (not the seed) must be refused and left byte-identical.
  inv="$(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/th \
    -e AUTONOMOUS_REPO=/tmp/r -e AUTONOMOUS_WORKTREE_ROOT=/tmp/wt \
    -v "$root/scripts/container-entrypoint.sh:/ep.sh:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /tmp/th /tmp/r && printf "{" > "$HOME/.claude.json" && sh /ep.sh trust-config; echo "rc=$? $(cat "$HOME/.claude.json")"' 2>&1)"
  if printf '%s' "$inv" | grep -q '\.claude\.json' && printf '%s' "$inv" | grep -q 'rc=1 {$'; then
    pass "invalid config refused, named, and left byte-identical"
  else
    fail "invalid config refused: $inv"
  fi

  if [ "${SMOKE_AGENT:-0}" = 1 ]; then
    scratch="$(make_target trust-agent)"
    mkdir -p "$scratch/.claude"
    printf '{"permissions":{"allow":["Bash(echo:*)"]}}\n' >"$scratch/.claude/settings.json"
    git -C "$scratch" add -A && git -C "$scratch" -c user.name=smoke -c user.email=smoke@example.com commit -q -m settings
    err="$(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/th -e ANTHROPIC_API_KEY -e CLAUDE_CODE_OAUTH_TOKEN \
      -e AUTONOMOUS_REPO=/work -e AUTONOMOUS_WORKTREE_ROOT=/tmp/wt \
      -v "$root/scripts/container-entrypoint.sh:/ep.sh:ro" -v "$scratch:/work" -w /work \
      --entrypoint sh "$IMAGE" -c 'mkdir -p /tmp/th && sh /ep.sh trust-config 2>/dev/null; claude -p "reply ok" 2>&1 >/dev/null' 2>&1)"
    if printf '%s' "$err" | grep -q 'has not been trusted'; then
      fail "trusted workspace still warns: $err"
    else
      pass "claude -p in a trusted workspace prints no untrusted warning"
    fi
  else
    skip "agent trust check (set SMOKE_AGENT=1)"
  fi
}

# Feature 036 (US4): does scope_guard still deny while the workspace is untrusted?
us_trust_hook() {
  echo "== Trust hook: strict containment under an untrusted workspace (feature 036)"
  if [ "${SMOKE_AGENT:-0}" != 1 ]; then
    skip "us-trust-hook (set SMOKE_AGENT=1; spends a few cents)"
    return
  fi
  scratch="$(make_target trust-hook)"
  mkdir -p "$scratch/.claude"
  cp -R priv/target_pack/.claude/. "$scratch/.claude/"
  git -C "$scratch" add -A && git -C "$scratch" -c user.name=smoke -c user.email=smoke@example.com commit -q -m pack
  ver="$(docker run --rm --entrypoint claude "$IMAGE" --version 2>/dev/null | tr -d '\r')"
  attempt() { # attempt <label> <trust: yes|no>
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/th -e ANTHROPIC_API_KEY -e CLAUDE_CODE_OAUTH_TOKEN \
      -e AUTONOMOUS_ORCHESTRATED=1 -e AUTONOMOUS_CONTAINMENT_PROFILE=strict \
      -e AUTONOMOUS_REPO=/work -e AUTONOMOUS_WORKTREE_ROOT=/tmp/wt -e TRUST="$2" \
      -v "$root/scripts/container-entrypoint.sh:/ep.sh:ro" -v "$scratch:/work" -w /work \
      --entrypoint sh "$IMAGE" -c 'mkdir -p /tmp/th; [ "$TRUST" = yes ] && sh /ep.sh trust-config 2>/dev/null
        claude -p "Write the text hi to /tmp/outside using the Write tool, then say done." --permission-mode acceptEdits >/tmp/out.txt 2>/tmp/err.txt
        printf "untrusted_warning=%s " "$(grep -c "has not been trusted" /tmp/err.txt)"
        printf "guard_denied=%s " "$(cat /tmp/out.txt /tmp/err.txt | grep -ci "write_outside_worktree\|outside worktree\|hook")"
        printf "file_written=%s\n" "$([ -e /tmp/outside ] && echo 1 || echo 0)"' 2>&1 | tail -1
  }
  u="$(attempt untrusted no)"
  t="$(attempt trusted yes)"
  echo "us-trust-hook claude=$ver untrusted: $u"
  echo "us-trust-hook claude=$ver trusted:   $t"
  case "$t" in *file_written=0*) pass "trusted workspace: out-of-tree write denied" ;; *) fail "trusted workspace: write not denied ($t)" ;; esac
  case "$u" in *guard_denied=0*) fail "untrusted workspace: no scope_guard denial seen (session may not have authenticated or attempted the write): $u"; return ;; esac
  case "$u" in *file_written=0*) pass "untrusted workspace: write still denied (hook ran)" ;; *) fail "untrusted workspace: write went through ($u) — record in docs/container.md" ;; esac
}

# Feature 037: declared system packages (--apt) and agent root (--agent-root).
# SMOKE_IMAGE=autonomous-release:local checks the release image the same way.
sysdeps() {
  echo "== System packages and agent root (feature 037)"
  ep="$root/scripts/container-entrypoint.sh"
  sd() { docker run --rm --user "$(id -u):$(id -g)" -v "$ep:/ep.sh:ro" --entrypoint sh "$IMAGE" -c "$1"; }

  if sd 'test -f /etc/autonomous/apt-packages' >/dev/null 2>&1; then
    for pkg in $(sd 'cat /etc/autonomous/apt-packages'); do
      check "declared package installed: $pkg" sd "dpkg -s '$pkg'"
    done
  else
    skip "no /etc/autonomous/apt-packages (image built without --apt)"
  fi

  probe="${SMOKE_SYSDEPS_PROBE:-pkg-config}"
  if sd 'command -v sudo' >/dev/null 2>&1; then
    check "sudo -n true" sd 'sudo -n true'
    case "$(sd 'sh /ep.sh agent-root 2>/dev/null')" in
      *AUTONOMOUS_AGENT_ROOT=1*) pass "entrypoint advertises agent root" ;;
      *) fail "entrypoint did not advertise agent root" ;;
    esac
    check "sudo apt-get install $probe" sd "sudo -n apt-get update && sudo -n apt-get install -y --no-install-recommends '$probe'"
    if sd "sudo -n apt-get remove -y '$probe'" >/dev/null 2>&1; then
      fail "apt-get remove was not refused (APT::Get::Remove)"
    else
      pass "apt-get remove refused"
    fi
  else
    check "no sudo in an image built without --agent-root" sh -c "! docker run --rm --entrypoint sh '$IMAGE' -c 'command -v sudo'"
    case "$(sd 'sh /ep.sh agent-root 2>/dev/null')" in
      *AUTONOMOUS_AGENT_ROOT=0*) pass "entrypoint does not advertise agent root" ;;
      *) fail "entrypoint advertised agent root without sudo" ;;
    esac
  fi
}

section="${1:-all}"
case "$section" in
  us1) us1 ;;
  us2) us2 ;;
  us3) us3 ;;
  us4) us4 ;;
  us5) us5 ;;
  us6) us6 ;;
  secrets) secrets ;;
  trust) trust ;;
  us-trust-hook) us_trust_hook ;;
  sysdeps) sysdeps ;;
  all) us1; us2; us3; us4; us5; us6; secrets; trust; us_trust_hook; sysdeps ;;
  *) echo "usage: scripts/container-smoke.sh [us1|us2|us3|us4|us5|us6|secrets|trust|us-trust-hook|sysdeps]" >&2; exit 2 ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "smoke: all checks passed"; else echo "smoke: $fails check(s) FAILED"; exit 1; fi
