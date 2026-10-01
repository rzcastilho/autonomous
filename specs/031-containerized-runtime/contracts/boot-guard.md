# Contract: Boot guards

Order inside `Autonomous.Application.start/2` (all before `Store.Boot.start!/0`):

1. `Autonomous.ContainerGuard.check!/0`
2. `check_no_retired_settings!/0` (unchanged)
3. `Autonomous.Instance.verify!/0` (container mode only)
4. `Autonomous.Store.Boot.start!/0` (unchanged)

`config/runtime.exs` retired-env refusals still run earlier, at config evaluation.

## `Autonomous.ContainerGuard`

```elixir
@spec decide(marker :: String.t() | nil, required? :: boolean()) :: :ok | {:error, :not_in_container}
@spec check!() :: :ok          # raises RuntimeError on {:error, _}
@spec containerized?() :: boolean()
```

| marker | `:require_container` | result |
|---|---|---|
| any | `false` (test config only) | `:ok` |
| `"1"` | `true` | `:ok` |
| anything else / unset | `true` | `{:error, :not_in_container}` |

`containerized?/0` is `required? and marker == "1"`, where `required?` is
`Application.get_env(:autonomous, :require_container, true)`. The marker alone is not
enough: inside the image `AUTONOMOUS_CONTAINER=1` is always set, and `mix test` run in
the container (`scripts/autonomous test`) must still behave like the host suite. The
`:test` config sets `require_container: false`, so in the test environment
`containerized?/0` is `false` on the host *and* in the container, and every
container-mode check below (`Instance.verify!/0`, `Instance.assert_served!/1`) is a
no-op. Truth table:

| marker | `:require_container` | `containerized?/0` |
|---|---|---|
| `"1"` | `true` | `true` |
| `"1"` | `false` (test, host or container) | `false` |
| other / unset | any | `false` |

Tests that exercise the container-mode branches call the pure functions with explicit
inputs (`decide/2`, `Instance.derive/3`, and a `verify/2`/`served?/2` pure core taking
the env and the derived identity) rather than flipping global config.

Refusal message (exact wording is a test assertion):

```text
autonomous refuses to start outside its container (AUTONOMOUS_CONTAINER is not set).
Run it with one of:
  scripts/autonomous shell   --target <repo>
  scripts/autonomous console --target <repo>
  scripts/autonomous release --target <repo>
`mix compile` and `mix test` still work on the host. This check prevents accidental
host starts; it is not a security boundary.
```

## `Autonomous.Instance.verify!/0`

No-op unless `ContainerGuard.containerized?/0`. Otherwise derives identity from
`Config.repo/0` and `Config.autonomous_root/0` and checks, in order:

| Check | Error term | Message names |
|---|---|---|
| lock held | `{:instance_unlocked, lock_path}` | lock path, "start through scripts/autonomous" |
| node | `{:instance_mismatch, :node, expected, actual}` | both node names, warns against ad hoc `--sname` |
| store dir | `{:instance_mismatch, :store_dir, expected, actual}` | both paths |

Raises `RuntimeError` with the term inspected plus the human sentence.

## `Autonomous.Instance.assert_served!/1`

```elixir
@spec assert_served!(String.t()) :: :ok   # raises Autonomous.Instance.NotServedError
```

No-op unless containerized. Accepts a path or a partition string (`"o:…"`/`"l:…"`).
Error message: `this instance serves <served repo>; <given> is not served here. Start
another instance with scripts/autonomous shell --target <given>.`

Applied through two call points in `lib/autonomous.ex`:

1. A new private helper `served_repo(opts)` that replaces every
   `Keyword.get(opts, :repo, Config.repo())` read (it calls `assert_served!/1` on the
   value and returns it). This one helper covers the private readers
   `find_parked_run/1`, `build_prune_plan/1`, `guard_repo_id/1` and
   `gather_taken_ids/1`, and the inline reads in `pending_questions/1`, `answer/4`,
   `run_history/1`, `export_run/3`, `run_detail/2` and `record_pr/3`.
2. A direct `assert_served!/1` call at the top of the functions that take a repository
   or repository id positionally: `workers/1`, `current_run_id/1`, `resumable/1`.

Resulting guarded public surface (each gets one test that passes a foreign `:repo` or
argument in container mode and expects `NotServedError`):

| Function | Repo input |
|---|---|
| `run/1`, `run_spec/2`, `preview_single_spec/2` | `:repo` option (via `served_repo/1`) |
| `workers/1`, `current_run_id/1` | positional `repo` |
| `resumable/1` | positional `repo_id` (partition string) |
| `pending_questions/1`, `answer/4` | `:repo` option |
| `continue_run/1`, `end_run/1` | `:repo` option (`find_parked_run/1`, `guard_repo_id/1`) |
| `resume/2`, `resume_run/1` | `:repo` option (`guard_repo_id/1`) |
| `run_history/1`, `run_detail/2`, `export_run/3`, `recover_record/1` | `:repo` option |
| `prune_preview/1`, `prune/1` | `:repo` option (`build_prune_plan/1`) |
| `record_pr/3`, `resolve_escalation/2` | `:repo` option |

A public function that later gains a `:repo` option must read it through
`served_repo/1`; a grep for `Keyword.get(opts, :repo` outside that helper must return
nothing (checked by a test).

## Release secret (`config/runtime.exs`, `:prod`)

`AUTONOMOUS_SECRET_KEY_BASE` unset or shorter than 64 bytes ⇒ raise
`AUTONOMOUS_SECRET_KEY_BASE is required for the release (generate one with
"openssl rand -base64 48")`. Evaluated before the app starts, so the store is never
opened.
