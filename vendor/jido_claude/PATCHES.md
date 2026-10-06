# Local patches to jido_claude

Base: `agentjido/jido_claude` @ `51f8b6e30cbf3839533d307399e12a136baf734f`
(upstream `main` `be65644` has the same gap, checked 2026-10-05).

1. `lib/jido_claude/adapter.ex`: add `:settings` to `@option_keys`, so
   `metadata["claude"][:settings]` (a `--settings` JSON string) is forwarded to
   `ClaudeAgentSDK.Options` instead of silently dropped. Needed by feature 032
   (`PhaseRequest` delivers shell timeouts on `--settings` so they beat a
   target's project `settings.json` `env`).

Remove this directory and restore the `github:` dep once upstream carries the key.
