# Contract: Instance identity

```elixir
@type t :: %Autonomous.Instance{
  repo: String.t(), partition: String.t(), segment: String.t(),
  node_name: atom(), store_dir: String.t(), lock_path: String.t(),
  owner_path: String.t(), cookie_path: String.t()
}

@spec derive(repo :: String.t(), partition :: String.t(), state_root :: String.t()) :: t()   # pure
@spec current() :: t()          # IO: RepoIdentity.partition(Config.repo()), Config.autonomous_root()
@spec print_env() :: :ok        # release eval entry point
```

## Rules

1. `segment = String.replace_prefix(partition, "o:", "") |> String.replace_prefix("l:", "")`
2. `node_name = :"autonomous_#{sanitize(segment)}@autonomous"`;
   `sanitize/1` replaces every char outside `[A-Za-z0-9_-]` with `_`.
3. `base = Path.join([state_root, "instances", segment])`;
   `store_dir = base/mnesia`, `lock_path = base/instance.lock`,
   `owner_path = base/instance.json`, `cookie_path = base/cookie`.
4. Host part `autonomous` is fixed by Compose `hostname: autonomous`.

## Properties (tested)

- Deterministic: same inputs ⇒ equal struct.
- SSH and HTTPS origin spellings of one repo ⇒ same identity (via `RepoIdentity`).
- Two different repos ⇒ different `segment`, `node_name`, `store_dir`.
- `store_dir` is never inside `repo`.
- `node_name` is a valid short node name for any segment (property test over arbitrary
  repo names, including dots and unicode).

## Mix task `mix autonomous.instance`

`mix autonomous.instance --repo <path> [--root <path>] --format env|segment|json`

Does not start the application (`@requirements []`; loads code only). `env` prints
`KEY=value` lines for the five `AUTONOMOUS_*` identity variables (see
[environment.md](environment.md)); `segment` prints the bare segment; exit 1 with a
message when `<path>` is not a git repository.
