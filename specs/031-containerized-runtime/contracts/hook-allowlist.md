# Contract: `scope_guard.py` change (FR-027, SC-010)

## Change

In `check_bash/2`, inside the redirect loop, skip a redirect whose captured target is
exactly one of:

```python
DEVICE_SINKS = {"/dev/null", "/dev/stdout", "/dev/stderr"}
```

Exact string match on the captured target, before `within(root, target)`. No other
rule, ordering, origin or profile logic changes. `PACK_CONTRACT` stays `3`
([research.md R12](../research.md)).

## Red-team matrix additions (`test/autonomous/scope_guard_test.exs`, real hook)

Origin `orchestrated`, profile `strict`, tool `Bash`:

| Command | Expected |
|---|---|
| `emulator -avd t -no-window > /dev/null 2>&1 &` | allow |
| `npx playwright test 2>/dev/null` | allow |
| `xvfb-run -a npm test &>/dev/null` | allow |
| `echo x > /dev/stdout` / `> /dev/stderr` | allow |
| `adb shell input tap 10 10` | allow |
| `import -window root shot.png` | allow |
| `./gradlew connectedAndroidTest` | allow |
| `echo x > /dev/sda` | deny `bash_redirect_outside_worktree` |
| `echo x > /dev/nullx` | deny `bash_redirect_outside_worktree` |
| `echo x > /dev/null/../../etc/passwd` | deny `bash_redirect_outside_worktree` |
| `echo x > /tmp/x` | deny `bash_redirect_outside_worktree` |
| `curl http://x > /dev/null` | deny `bash_curl` (rule order unchanged) |
| every existing case | unchanged result |

Known, unchanged behaviour: `bash_curl`/`bash_wget` are anchored at the start of the
command string, so `true; curl http://x` is not denied today. This feature neither
relies on nor changes that; it is recorded with the egress gap in
`docs/enforcement.md`.

Under `permissive` and `interactive`, all rows allow (unchanged).
