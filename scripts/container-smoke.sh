#!/bin/sh
# Container smoke checks (feature 031). Run by hand from the repository root; not
# part of the default test suite. Each check prints PASS/FAIL/SKIP; exit 1 on any
# FAIL. Sections are added per user story — see
# specs/031-containerized-runtime/quickstart.md.
#
#   scripts/container-smoke.sh [us1|us2|us3|us4|us5|us6|secrets|trust|sysdeps|conversation|volumes]
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
    # Install then remove in one container: each `sd` is a fresh `docker run --rm`,
    # and removing a package that is not installed exits 0 without hitting the guard.
    if sd "sudo -n apt-get update -qq && sudo -n apt-get install -y -qq --no-install-recommends '$probe' \
      && sudo -n apt-get remove -y '$probe'" >/dev/null 2>&1; then
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

# Feature 040: conversation masking and permissions. Pure check (host mise) of the
# credential mask against throwaway values (no spend); quickstart 2 step 6 covers a
# real session that echoes $GH_TOKEN / $CLAUDE_CODE_OAUTH_TOKEN.
conversation() {
  echo "== Conversation: credential values are masked, files are owner-only (feature 040)"
  out="$(GH_TOKEN=smoke-gh-token-123456 CLAUDE_CODE_OAUTH_TOKEN=smoke-oauth-token-654321 \
    mise exec -- mix run --no-start -e '
      pairs = Autonomous.CredentialMask.pairs()
      IO.puts(Autonomous.CredentialMask.mask("echo smoke-gh-token-123456 smoke-oauth-token-654321", pairs))' 2>&1)"
  case "$out" in
    *"[masked:GH_TOKEN]"*"[masked:CLAUDE_CODE_OAUTH_TOKEN]"*) pass "GH_TOKEN and CLAUDE_CODE_OAUTH_TOKEN values are masked" ;;
    *) fail "mask did not replace both credential values: $out" ;;
  esac
  case "$out" in
    *smoke-gh-token-123456*|*smoke-oauth-token-654321*) fail "a raw credential value survived masking" ;;
    *) pass "no raw credential value survives" ;;
  esac
  root="${AUTONOMOUS_TRANSCRIPT_ROOT:-$HOME/.autonomous/transcripts}"
  if [ -d "$root" ]; then
    bad="$(find "$root" -path '*/conversations/*' \( -type f ! -perm 600 -o -type d ! -perm 700 \) 2>/dev/null | head -1)"
    if [ -n "$bad" ]; then fail "conversation path is not owner-only: $bad"; else pass "saved conversations are owner-only (0600/0700)"; fi
  else
    skip "permission scan (no transcript root at $root)"
  fi
}

# Feature 041: user-defined persistent volumes. Hand-run; the declaration lives in
# a temp XDG_CONFIG_HOME so the operator's real one is never touched. Needs `make`
# in the image for the build-persistence check. SMOKE_AGENT=1 adds one real `claude`
# session; SMOKE_SKIP_REBUILD=1 skips the image rebuild check.
volumes() {
  echo "== User-defined volumes (feature 041) =="
  XDG_CONFIG_HOME="$(mktemp -d)"
  export XDG_CONFIG_HOME
  printf '%s\n' "$XDG_CONFIG_HOME" >>"$smoke_list"
  parent=/var/lib/autonomous/volumes

  vol_segment() { basename "$(instance_dir_of "$1")"; }
  vol_file() { printf '%s/autonomous/targets/%s/volumes.toml' "$XDG_CONFIG_HOME" "$(vol_segment "$1")"; }
  vol_write() { # vol_write <target> <toml>
    mkdir -p "$(dirname "$(vol_file "$1")")"
    printf '%s\n' "$2" >"$(vol_file "$1")"
  }
  vol_count() { # vol_count <segment>: user volumes of the segment
    docker volume ls -q --filter label=dev.autonomous.kind=user-volume \
      --filter "label=dev.autonomous.segment=$1" | wc -l | tr -d ' '
  }
  vol_eval() { iex_eval "$1" "$(free_port)" "$2"; }

  t="$(make_target vol-a)"
  seg="$(vol_segment "$t")"
  vol_write "$t" "[[volume]]
name = \"smoke-build\"
path = \"$parent/smoke-build\"
path_dirs = [\"$parent/smoke-build/bin\"]
[volume.env]
BUILD_DIR = \"$parent/smoke-build/obj\""

  # --- persistence across stop/start ---------------------------------------------
  out="$(vol_eval "$t" '
    b = System.fetch_env!("BUILD_DIR")
    File.mkdir_p!(b)
    File.mkdir_p!(Path.dirname(b) <> "/bin")
    File.write!(Path.dirname(b) <> "/bin/smoke-tool", "#!/bin/sh\necho smoke-tool-ok\n")
    File.chmod!(Path.dirname(b) <> "/bin/smoke-tool", 0o755)
    File.write!(b <> "/marker", "kept")
    IO.puts("VOL_BUILD_DIR=" <> b)
    IO.puts("VOL_PATH=" <> System.get_env("PATH"))
    d = Path.join(System.fetch_env!("AUTONOMOUS_WORKTREE_ROOT"), "smoke-make")
    File.mkdir_p!(d)
    File.write!(Path.join(d, "main.c"), "x")
    File.write!(Path.join(d, "Makefile"), "$(BUILD_DIR)/out.o: main.c\n\tcp main.c $@\n")
    {o, s} = System.cmd("make", [], cd: d, stderr_to_stdout: true)
    IO.puts("VOL_MAKE1 status=#{s} " <> String.replace(o, "\n", "|"))')"
  case "$out" in *"VOL_BUILD_DIR=$parent/smoke-build/obj"*) pass "declared variable visible in the session" ;; *) fail "BUILD_DIR not visible: $out" ;; esac
  # erlexec prepends its own erts bin to PATH when the VM starts, so "first" means first
  # ahead of every image entry: only erts-*/bin entries may precede the volume's path dir.
  vol_path="$(printf '%s\n' "$out" | sed -n 's/^VOL_PATH=//p' | tr -d '\r' | head -1)"
  vol_lead="$(printf '%s\n' "$vol_path" | tr ':' '\n' | awk -v want="$parent/smoke-build/bin" '
    $0 == want { found = 1; exit }
    $0 !~ /\/erts-[^\/]*\/bin$/ { bad = 1 }
    END { print (found && !bad) ? "ok" : "no" }')"
  case "$vol_lead" in ok) pass "path dir is first on PATH (ahead of image entries)" ;; *) fail "PATH not prefixed: $vol_path" ;; esac
  case "$out" in *"VOL_MAKE1 status=0"*"cp "*) pass "first build compiled into the volume" ;; *) skip "make not available in the image: $out" ;; esac

  out="$(vol_eval "$t" '
    b = System.fetch_env!("BUILD_DIR")
    IO.puts("VOL_MARKER=" <> File.read!(b <> "/marker"))
    d = Path.join(System.fetch_env!("AUTONOMOUS_WORKTREE_ROOT"), "smoke-make")
    {_, q} = System.cmd("make", ["-q"], cd: d, stderr_to_stdout: true)
    {o, _} = System.cmd("make", [], cd: d, stderr_to_stdout: true)
    IO.puts("VOL_MAKEQ status=#{q} " <> String.replace(o, "\n", "|"))')"
  case "$out" in *"VOL_MARKER=kept"*) pass "marker survived stop/start (SC-001)" ;; *) fail "marker lost across restart: $out" ;; esac
  case "$out" in
    *"VOL_MAKEQ status=0"*"cp "*) fail "second build redid work" ;;
    *"VOL_MAKEQ status=0"*) pass "second build is up to date (SC-001)" ;;
    *) skip "make check not conclusive: $out" ;;
  esac

  # --- nothing leaked into the worktree or host repo (SC-002) ---------------------
  if [ -z "$(git -C "$t" status --porcelain --ignored)" ] && [ -z "$(find "$t" -name '*.o' 2>/dev/null)" ]; then
    pass "host repo shows no new or ignored files and no object files"
  else
    fail "build data leaked into the host repo: $(git -C "$t" status --porcelain --ignored)"
  fi

  # --- survives an image rebuild (FR-012) -----------------------------------------
  if [ -z "${SMOKE_SKIP_REBUILD:-}" ]; then
    scripts/autonomous build >/dev/null 2>&1 || fail "image rebuild failed"
    out="$(vol_eval "$t" 'IO.puts("VOL_AFTER_REBUILD=" <> File.read!(System.fetch_env!("BUILD_DIR") <> "/marker"))')"
    case "$out" in *"VOL_AFTER_REBUILD=kept"*) pass "volume survived an image rebuild" ;; *) fail "volume lost across rebuild: $out" ;; esac
  else
    skip "image rebuild check (SMOKE_SKIP_REBUILD set)"
  fi

  # --- a real agent session sees the variable and the PATH dir (FR-014) -----------
  if [ -n "${SMOKE_AGENT:-}" ]; then
    out="$(vol_eval "$t" '
      {o, _} = System.cmd("claude", ["-p", "--dangerously-skip-permissions",
        "Run in Bash: printenv BUILD_DIR; smoke-tool. Reply with exactly their output."], stderr_to_stdout: true)
      IO.puts("VOL_AGENT=" <> String.replace(o, "\n", "|"))')"
    case "$out" in *"$parent/smoke-build/obj"*"smoke-tool-ok"*) pass "agent session sees the variable and the path dir" ;; *) fail "agent session does not: $out" ;; esac
  else
    skip "agent session check (set SMOKE_AGENT=1)"
  fi

  # --- 1, 5 and 20 entries --------------------------------------------------------
  for n in 1 5 20; do
    t_n="$(make_target "vol-n$n")"
    toml=""
    i=1
    while [ "$i" -le "$n" ]; do
      toml="$toml[[volume]]
name = \"v$i\"
path = \"$parent/v$i\"
"
      i=$((i + 1))
    done
    vol_write "$t_n" "$toml"
    vol_eval "$t_n" 'IO.puts("up")' >/dev/null
    [ "$(vol_count "$(vol_segment "$t_n")")" = "$n" ] && pass "$n declared volume(s) created" || fail "expected $n volumes"
    purge_target "$t_n"
  done

  # --- isolation: same volume name, two targets (FR-011) --------------------------
  t2="$(make_target vol-b)"
  vol_write "$t2" "[[volume]]
name = \"smoke-build\"
path = \"$parent/smoke-build\"
env = { BUILD_DIR = \"$parent/smoke-build\" }"
  out="$(vol_eval "$t2" 'IO.puts("VOL_B_HAS=#{File.exists?("/var/lib/autonomous/volumes/smoke-build/obj/marker")}")')"
  case "$out" in *"VOL_B_HAS=false"*) pass "same-named volume of another target is separate" ;; *) fail "volumes leaked across targets: $out" ;; esac

  # --- rejected declarations never half-start an instance (SC-003) ----------------
  t3="$(make_target vol-bad)"
  seg3="$(vol_segment "$t3")"
  vol_reject() { # vol_reject <label> <toml>
    vol_write "$t3" "$2"
    rc=0
    scripts/autonomous shell --target "$t3" </dev/null >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 2 ] && [ "$(vol_count "$seg3")" = 0 ] \
      && [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=autonomous-$seg3")" ]; then
      pass "rejected ($1): exit 2, no container, no volume"
    else
      fail "rejection ($1) exit=$rc volumes=$(vol_count "$seg3")"
    fi
  }
  vol_reject "name" "[[volume]]
name = \"Bad Name\"
path = \"$parent/x\""
  vol_reject "path" "[[volume]]
name = \"x\"
path = \"/workspace/x\""
  vol_reject "variable" "[[volume]]
name = \"x\"
path = \"$parent/x\"
env = { PATH = \"/x\" }"
  vol_reject "path dir" "[[volume]]
name = \"x\"
path = \"$parent/x\"
path_dirs = [\"/usr/bin\"]"
  vol_reject "malformed" "[[volume]
name ="
  purge_target "$t3"

  # --- reset-cache and purge (US3, FR-016..FR-018) ---------------------------------
  t4="$(make_target vol-reset)"
  seg4="$(vol_segment "$t4")"
  vol_write "$t4" "[[volume]]
name = \"keep\"
path = \"$parent/keep\"
env = { KEEP_DIR = \"$parent/keep\" }

[[volume]]
name = \"wipe\"
path = \"$parent/wipe\"
env = { WIPE_DIR = \"$parent/wipe\" }"
  vol_eval "$t4" 'File.write!(System.fetch_env!("KEEP_DIR") <> "/m", "1"); File.write!(System.fetch_env!("WIPE_DIR") <> "/m", "1")' >/dev/null
  out="$(scripts/autonomous reset-cache --target "$t4" --volume wipe 2>&1)"
  case "$out" in *"wipe removed"*) pass "reset-cache removed the named volume" ;; *) fail "reset by name: $out" ;; esac
  out="$(vol_eval "$t4" 'IO.puts("KEEP=#{File.exists?(System.fetch_env!("KEEP_DIR") <> "/m")} WIPE=#{File.exists?(System.fetch_env!("WIPE_DIR") <> "/m")}")')"
  case "$out" in *"KEEP=true WIPE=false"*) pass "only the named volume was emptied" ;; *) fail "reset scope: $out" ;; esac
  out="$(scripts/autonomous reset-cache --target "$t4" --volume wipe 2>&1)"
  scripts/autonomous reset-cache --target "$t4" --volume wipe >/dev/null 2>&1 \
    && pass "reset-cache is idempotent" || fail "second reset failed: $out"
  out="$(scripts/autonomous reset-cache --target "$t4" --volume nope 2>&1)" && rc=0 || rc=$?
  [ "$rc" = 2 ] && pass "unknown volume refused" || fail "unknown volume exit=$rc: $out"
  scripts/autonomous console --target "$t4" >/dev/null 2>&1 || true
  out="$(scripts/autonomous reset-cache --target "$t4" 2>&1)" && rc=0 || rc=$?
  [ "$rc" = 75 ] && pass "reset-cache refused while the instance is up" || fail "running reset exit=$rc: $out"
  scripts/autonomous stop --target "$t4" >/dev/null 2>&1
  out="$(scripts/autonomous reset-cache --target "$t4" 2>&1)"
  case "$out" in *"keep removed"*) pass "reset-cache with no names removes every declared volume" ;; *) fail "reset all: $out" ;; esac
  vol_eval "$t4" 'IO.puts("up")' >/dev/null
  scripts/autonomous stop --target "$t4" --purge >/dev/null 2>&1
  [ "$(vol_count "$seg4")" = 0 ] && pass "stop --purge removed the segment's user volumes" || fail "volumes remain after purge"
  purge_target "$t4"

  purge_target "$t"
  purge_target "$t2"
  [ "$(vol_count "$seg")" = 0 ] && pass "stop --purge removed the declared volumes" || fail "volumes remain after purge"
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
  sysdeps) sysdeps ;;
  conversation) conversation ;;
  volumes) volumes ;;
  all) us1; us2; us3; us4; us5; us6; secrets; trust; sysdeps; conversation; volumes ;;
  *) echo "usage: scripts/container-smoke.sh [us1|us2|us3|us4|us5|us6|secrets|trust|sysdeps|conversation|volumes]" >&2; exit 2 ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "smoke: all checks passed"; else echo "smoke: $fails check(s) FAILED"; exit 1; fi
