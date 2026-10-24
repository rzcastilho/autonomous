# Contract: orchestrator integration

## `Autonomous.ContainerEngine` (new, `lib/autonomous/container_engine.ex`)

```elixir
@spec advertised?(env :: %{String.t() => String.t()}) :: boolean()   # default System.get_env()
@spec requested?(env :: %{String.t() => String.t()}) :: boolean()
@spec prompt_note(boolean()) :: String.t()        # "" for false; "\n\n" <> Prompts.load("container_engine")
@spec probe(keyword()) :: {:ok, version :: String.t()} | {:error, cause :: String.t()}
@spec cleanup(keyword()) :: :skipped | :clean | {:residue, residue(), cause()}
@spec after_boundary(Feature.t(), atom(), keyword()) :: :ok   # cleanup + logging + telemetry
```

These are the only env reads: `advertised?/1` and `requested?/1`. Everything else
takes its inputs explicitly.

**Options** (`probe/1`, `cleanup/1`, `after_boundary/3`):
- `:advertised?` — boolean. Defaults to `advertised?/1`. `false` makes
  `cleanup/1` return `:skipped` with **zero** CLI calls.
- `:cli` — the module implementing `Autonomous.ContainerEngine.Cli`. Defaults to
  `Config.container_engine_cli/0`.
- `:timeout_ms` — a hard bound on the whole cleanup or probe. Defaults are
  `Config.container_engine_cleanup_timeout_ms/0` (120 000) and 5 000 for the
  probe.

**`cleanup/1` command order**:
1. `ps -aq`
2. `rm -f -v <ids>`, only if the list is non-empty
3. `network prune -f`
4. `volume prune -af`
5. verification: `ps -aq`, `network ls -q --filter type=custom`, `volume ls -q`

It never calls `image prune`, `builder prune`, `system prune` or `rmi` (a
hermetic test asserts the stub received none of them).

**Execution**: The whole sequence runs in
`Task.Supervisor.async_nolink(Autonomous.SessionSup, …)` and is collected with
`Task.yield(t, timeout) || Task.shutdown(t, :brutal_kill)`.
- A timeout yields `{:residue, unknown, :timeout}`.
- A task crash yields `{:residue, unknown, {:crash, reason}}`.
- The caller never raises.

## `Autonomous.ContainerEngine.Cli` (behaviour + default impl)

```elixir
@callback run([String.t()], timeout_ms :: pos_integer()) ::
            {:ok, stdout :: String.t()} | {:error, {:exit, status :: integer(), output :: String.t()}}
```

The default implementation calls `System.cmd("docker", args, stderr_to_stdout:
true)`. The environment is inherited, so `DOCKER_HOST` comes from the container.

## `after_boundary/3` (the FeatureRunner seam)

```text
after_boundary(feature, phase, opts):
  case cleanup(opts):
    :skipped -> :ok                                     # no log line, no telemetry
    :clean   -> Logger.debug + telemetry(result: :clean)
    {:residue, r, cause} ->
       Logger.error("container engine: cleanup after feature <label> (<phase>) left
                     <n> containers, <n> networks, <n> volumes (<cause>) — the next
                     phase boundary retries; images and build cache are kept")
       telemetry(result: :residue, residue: r)
  :ok
```

The telemetry event is `[:speckit, :engine, :cleanup]`, with measurements
`%{duration: native}` and metadata `%{feature_id, phase, result, residue}`.
`Telemetry.attach_default_logger/0` attaches it.

## `FeatureRunner` call sites

The engine setting is resolved once in `run/2`:

```elixir
engine = Keyword.get_lazy(opts, :engine, fn -> [advertised?: ContainerEngine.advertised?()] end)
```

`after_boundary/3` is then called at three sites:

| Site | Wrapping | `phase` argument |
|---|---|---|
| `loop/12` around `run_step/8` | `try do run_step(…) after ContainerEngine.after_boundary(feature, phase, engine) end` | the pipeline phase (`:implement` once, after the whole chunk loop) |
| `run_remediation/5` (pre-phase remediation) | the same `try … after` around the `remediation.run` call | `:remediation` |
| the describe session in `commit_message_and_pr` | the same, around the describe call | `:describe` |

Invariants:
- **Outcome.** The value returned by the wrapped call is returned unchanged.
  `after_boundary/3` returns `:ok` and its result is discarded (FR-010a).
- **Raises.** A raise inside the wrapped call still triggers cleanup, then
  re-raises into the existing `catch` in `run/2`.
- **No sessions.** Cleanup never starts a session and never consults
  `Workers.drain_requested?/0`. It runs on drain too.
- **Chunks.** `ChunkRunner` and `Chunking` are not modified. There is no
  cleanup between chunks.

## `PhaseRequest`

The `build/3` option is `:container_engine`, a boolean defaulting lazily to
`ContainerEngine.advertised?/0`.
- **Prompt.** `true` on `:implement` or `:converge` appends
  `ContainerEngine.prompt_note(true)` after the agent-root note and before
  resume, clarify and background-retry. Any other phase, or `false`, leaves the
  prompt byte-identical.
- **Launch env and settings.** No change. Sessions inherit `DOCKER_HOST` from the
  container env.

`build_remediation/3` takes no note (FR-013 names implement and converge only).

## `priv/prompts/container_engine.md` (new prompt pack)

It is added to the `Prompts` allow-list. Its content says, in substance:
- **Engine.** A container engine is available through `DOCKER_HOST`: the
  `docker` CLI, `docker compose` and `docker buildx`. Use it for image builds,
  service containers and compose stacks the target's tests need.
- **Mounts.** Bind-mount only paths under the feature worktree or the target
  repository. `/tmp`, `$HOME` and `/workspace` resolve to a different filesystem
  inside the engine. Stage files under the worktree.
- **Ports.** Published ports are reachable on `localhost`. Ports 2375, 4000, 4369
  and 6080 are reserved.
- **Cleanup.** Every container, network and volume is removed when this phase
  ends. Images and build cache are kept. Do not rely on a stack surviving into a
  later phase.

## `Config` (new accessors)

| Accessor | Default |
|---|---|
| `container_engine_cli/0` | `Autonomous.ContainerEngine.Cli` |
| `container_engine_cleanup_timeout_ms/0` | `120_000` |
