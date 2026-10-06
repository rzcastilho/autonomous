This session is headless. Ending your turn ends the session; nothing resumes it
and nothing collects background work afterwards.

- Run every command in the foreground. For long commands (test suites, builds,
  screenshot runs) pass an explicit long `timeout` on the Bash call.
- Never use `run_in_background`, never start a background watcher, and never
  plan to "wait for" a command to finish later.
- Never end your turn while a command is still running.
- If a command is moved to the background anyway, read its output file until
  it has finished before doing anything else.
