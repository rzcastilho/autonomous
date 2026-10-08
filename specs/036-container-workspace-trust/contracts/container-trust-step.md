# Contract: Container Trust Step (US1–US3)

Applies to every container shape that runs sessions for a target: dev
`shell`/`console`, release `release` (FR-009). The host path is untouched
(FR-012).

## Placement (`scripts/container-entrypoint.sh`)

```text
1. derive identity          (exports AUTONOMOUS_* incl. AUTONOMOUS_WORKTREE_ROOT — contracts/environment.md)
2. take per-target lock
3. owner record + cookie
4. git / gh credentials
4b. seed_cli_config         (feature 034, --with-login only)
4c. trust_workspaces        ← NEW: always, after any seed, before any CLI/VM process
5. warnings …
7. exec VM
```

No CLI process exists in the container before step 7, so the step has no
concurrent writer.

## Inputs

| Var | Required | Meaning |
|---|---|---|
| `HOME` | yes | the step writes only `$HOME/.claude.json` |
| `AUTONOMOUS_REPO` | yes | target repository |
| `AUTONOMOUS_WORKTREE_ROOT` | yes | instance worktree root (Elixir-derived) |

Both paths are canonicalised with `realpath` semantics (`os.path.realpath`);
a non-existent worktree root resolves through its existing prefix.

## Behaviour

| Condition | Behaviour | Exit |
|---|---|---|
| `$HOME/.claude.json` absent | create `{"projects": {repo: {"hasTrustDialogAccepted": true}, root: {…}}}`, mode `0600`, atomic | 0 |
| valid object, either record missing or not `true` | set `hasTrustDialogAccepted: true` on both, keep every other key (top level and inside each project entry), atomic replace, mode `0600` | 0 |
| valid object, both already `true` | **no write** — file byte-identical, mtime unchanged | 0 |
| not JSON / top level not an object / `projects` not an object | `die "container CLI config $HOME/.claude.json is not a JSON object: <parser message>; not modified"` | ≠0 |
| `AUTONOMOUS_WORKTREE_ROOT` unset/empty | `die` naming the variable | ≠0 |

Atomic replace = write `$HOME/.claude.json.tmp.<pid>` (`O_CREAT|O_EXCL`,
`0600`), `fsync`, `os.replace` onto `$HOME/.claude.json`. Never written in
place (FR-005). One log line on success: `autonomous: trusted <repo> and <root>
for agent sessions` (or `… already trusted` on the no-write path).

## Guarantees

- **T1 (exact set, FR-003).** The step adds trust for exactly the two paths.
  It never adds a record for an ancestor (`$HOME`, `/`, `$AUTONOMOUS_ROOT`),
  another instance's paths, or `/workspace`. Records already present in a
  seeded config are carried over unchanged, `true` or `false`.
- **T2 (preservation, FR-004).** Every key/value other than the two
  `hasTrustDialogAccepted` flags is preserved (JSON value equality; key order
  kept).
- **T3 (idempotent, FR-006).** Running the step N times equals running it once;
  N ≥ 2 performs no write.
- **T4 (host untouched, FR-007).** The step reads/writes only the
  container-private `$HOME/.claude.json`. The host file reaches the container
  only through 034's read-only seed mount.
- **T5 (effective trust, US1).** On the pinned CLI, the repo record makes
  sessions in the repo, its subdirectories and all its `git worktree`s trusted
  (research R1). The worktree-root record is bounded and forward-compatible;
  it is not what makes worktree sessions trusted today.

## Smoke hook

`container-entrypoint.sh trust-config` — runs `seed_cli_config` then
`trust_workspaces` and exits 0, before build, identity or lock work. Reads
`AUTONOMOUS_REPO`/`AUTONOMOUS_WORKTREE_ROOT` from the environment (the caller
supplies them; no identity derivation). Used by the hermetic test and
`scripts/container-smoke.sh trust`.

## Smoke checks (`scripts/container-smoke.sh trust`, FR-011)

| Check | Spend |
|---|---|
| no config → file created, `0600`, `projects` keys == {repo, root} | none |
| seeded config with unrelated keys + a third trusted path + repo explicitly `false` → all original keys equal, third path untouched, repo now `true`, root `true` | none |
| run step 1, 2 and 5 times → file byte-identical after run 1; exactly 2 records added | none |
| invalid config (`{`) → non-zero exit naming the file; file byte-identical | none |
| host `~/.claude.json` sha256 equal before/after a `--with-login` instance start + stop | none |
| `SMOKE_AGENT=1`: one `claude -p` in a worktree of a scratch target with allow entries → stderr has no `has not been trusted` | a few cents |
| `SMOKE_AGENT=1` `us-trust-hook`: strict-marker session, trust withheld, asked to write outside the tree → record whether `scope_guard` denied it; repeat trusted → denied | a few cents |
