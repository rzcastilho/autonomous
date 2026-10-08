# Contract: Instance environment — `AUTONOMOUS_WORKTREE_ROOT` (amends 031 `contracts/environment.md`)

`Autonomous.Instance.env_lines/1` (and therefore `mix autonomous.instance
--format env` and `Autonomous.Instance.print_env/0`) emits **six** identity
lines; the new one is last so existing `grep '^AUTONOMOUS_'` consumers are
unaffected:

```text
AUTONOMOUS_INSTANCE_SEGMENT=<segment>
AUTONOMOUS_NODE_NAME=<node>
AUTONOMOUS_STORE_DIR=<root>/instances/<segment>/mnesia
AUTONOMOUS_COOKIE_PATH=<root>/instances/<segment>/cookie
AUTONOMOUS_INSTANCE_LOCK=<root>/instances/<segment>/instance.lock
AUTONOMOUS_WORKTREE_ROOT=<root>/worktrees/<segment>        # NEW (036)
```

- Value is produced by the same function `Autonomous.Layout` uses for its
  `worktree_root` (one derivation; a test asserts equality for the same
  repo/root).
- Reader: `scripts/container-entrypoint.sh` `trust_workspaces` only. Nothing in
  `runtime.exs` reads it; the BEAM keeps deriving the worktree root from
  `AUTONOMOUS_ROOT` + segment as today.
- The entrypoint never recomputes it (031 rule: identity derived only in Elixir).
