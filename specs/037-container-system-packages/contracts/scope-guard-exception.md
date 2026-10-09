# Contract: `scope_guard.py` pack contract 5 — strict package-manager exception

Supersedes the `bash_sudo` row of the contract-4 strict rule set for one cell only.

## Contract probe

`python3 scope_guard.py --contract` ⇒ `5`.

## Marker resolution

`agent_root_active(env)` ⇔ `env.get("AUTONOMOUS_CONTAINER") == "1" and env.get("AUTONOMOUS_AGENT_ROOT") == "1"`.

Origin/profile resolution is unchanged. Interactive ⇒ allow; permissive ⇒ allow;
unparseable stdin ⇒ deny (all unchanged).

## Strict Bash evaluation

```text
for rule in DANGEROUS_BASH (order unchanged):
    if rule.id == "bash_sudo" and agent_root_active and sudo_allowed(cmd): continue
    if rule matches: deny(rule.id, detail)
redirect-outside-worktree check (unchanged)
```

`detail` for `bash_sudo`: `sudo` without agent root (unchanged);
`sudo (agent root allows only apt-get/apt update|install and dpkg queries)` with it.

## `sudo_allowed(cmd)` grammar

Deny (return false) if any of:

1. `` ` ``, `$(`, `<(`, `>(` appear anywhere, or a `(`/`)` token is produced.
2. `shlex` (posix, `punctuation_chars=True`) raises.
3. a `sudo` token is not the first token of its segment (segments split on
   `&&`, `||`, `;`, `|`, `&`, newline).
4. a segment starting with `sudo` does not parse as:

```text
segment   := "sudo" ["-n"] ["DEBIAN_FRONTEND=noninteractive"] pm_call
pm_call   := ("apt-get" | "apt") "update" opts*
           | ("apt-get" | "apt") "install" (opt | pkg)* pkg (opt | pkg)*
           | "apt" ("list" | "show" | "policy") (opt | pattern)*
           | "dpkg" dpkg_query (pattern)*
opt       := "-y" | "--yes" | "--assume-yes" | "-q" | "-qq" | "--quiet" | "--no-install-recommends"
pkg       := /^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+)?$/
pattern   := any token not starting with "-" and not containing "/"
dpkg_query:= "-l" | "--list" | "-s" | "--status" | "-L" | "--listfiles"
           | "-S" | "--search" | "--get-selections"
```

Otherwise true. Non-`sudo` segments are not judged by the grammar (they remain
subject to every other rule, evaluated on the whole command as today).

## Required red-team rows (scope_guard_test, SC-003)

Env pinned: `AUTONOMOUS_ORCHESTRATED`, `AUTONOMOUS_CONTAINMENT_PROFILE`,
`CLAUDE_CODE_ENTRYPOINT`, `AUTONOMOUS_CONTAINER`, `AUTONOMOUS_AGENT_ROOT` cleared
then set per row.

| # | Markers | Command | Expect |
|---|---|---|---|
| 1 | none | `sudo apt-get install -y pkg-config` | deny `bash_sudo` detail `sudo` |
| 2 | container only | same | deny (unchanged) |
| 3 | agent root only | same | deny (unchanged) |
| 4 | both | same | allow |
| 5 | both | `sudo apt-get update && sudo apt-get install -y --no-install-recommends libasound2-dev pkg-config` | allow |
| 6 | both | `sudo -n DEBIAN_FRONTEND=noninteractive apt install -y libfoo-dev` | allow |
| 7 | both | `sudo dpkg -s libasound2-dev` / `sudo apt list --installed` | allow |
| 8 | both | `sudo apt-get remove x` / `purge` / `autoremove` / `upgrade` / `dist-upgrade` | deny |
| 9 | both | `sudo apt-get install -o APT::Update::Pre-Invoke::=sh x` / `-c f` / `--option …` | deny |
| 10 | both | `sudo apt-get install ./x.deb` / `/tmp/x.deb`; `sudo dpkg -i x.deb` | deny |
| 11 | both | `sudo sh -c 'apt-get install x'`; `sudo -E apt-get install x`; `sudo -u root apt-get install x` | deny |
| 12 | both | `sudo apt-get install -y x; sudo rm -rf /tmp/y` / `\| sudo tee /etc/x` | deny |
| 13 | both | `sudo apt-get install $(cat f)` / `` `cat f` `` | deny |
| 14 | both | `echo sudo` / `ls "sudo apt-get install x"` | deny (sudo not at segment start) |
| 15 | both | `sudo apt-get install -y x && curl http://y` | allow the sudo; whole-command rules unchanged (`^\s*curl` does not match mid-command — identical to today's behaviour for that shape) |
| 16 | both | `sudo apt-get install -y x > /etc/out` | deny `bash_redirect_outside_worktree` |
| 17 | both, profile permissive | rows 8–13 | allow (permissive unchanged) |
| 18 | both, interactive | rows 8–13 | allow (interactive unchanged) |
| 19 | both | unbalanced quote `sudo apt-get install "x` | deny |
| 20 | any | `git push`, `wget`, `curl` at start, WebFetch | unchanged denials |
