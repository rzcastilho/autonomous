#!/usr/bin/env python3
"""PreToolUse scope guard for orchestrator-driven worktrees.

The Claude adapter runs the CLI with --dangerously-skip-permissions, so this
hook is the enforcement boundary. It reads the PreToolUse JSON on stdin and
DENIES:

  * file writes (Write / Edit / MultiEdit / NotebookEdit) whose target resolves
    outside the worktree (the hook's `cwd`);
  * Bash commands matching dangerous patterns, or that redirect to an absolute
    path outside the worktree.

Everything else is allowed (exit 0, no output). A deny is emitted as the
Claude Code hook JSON with permissionDecision "deny". Unparseable input fails
closed (denied) — a guard that can't read its input must not wave writes through.
"""

import sys
import os
import re
import json

FILE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

DANGEROUS_BASH = [
    (r"\brm\s+-rf\s+/(?:\s|$)", "rm -rf /"),
    (r"\brm\s+-rf\s+~", "rm -rf ~"),
    (r"\bsudo\b", "sudo"),
    (r"\bgit\s+push\b", "git push (the orchestrator owns git)"),
    (r"curl\b[^|]*\|\s*(?:sh|bash)", "curl | sh"),
    (r"wget\b[^|]*\|\s*(?:sh|bash)", "wget | sh"),
    (r":\s*\(\s*\)\s*\{.*\|.*&\s*\}", "fork bomb"),
    (r"\bchmod\s+-R\s+777\s+/", "chmod -R 777 /"),
]


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def allow():
    sys.exit(0)


def within(root, path):
    if not path:
        return True
    ap = path if os.path.isabs(path) else os.path.join(root, path)
    ap = os.path.realpath(ap)
    return ap == root or ap.startswith(root + os.sep)


def check_bash(cmd, root):
    for pattern, name in DANGEROUS_BASH:
        if re.search(pattern, cmd):
            return name
    # Redirections to an absolute path outside the worktree.
    for match in re.finditer(r">>?\s*\"?(/[^\"\s]+)", cmd):
        target = match.group(1)
        if not within(root, target):
            return "redirect outside worktree: " + target
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        deny("scope_guard: unparseable hook input")

    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    root = os.path.realpath(data.get("cwd") or os.getcwd())

    if tool in FILE_TOOLS:
        for key in ("file_path", "notebook_path"):
            path = tool_input.get(key)
            if path is not None and not within(root, path):
                deny("scope_guard: write outside worktree denied: " + str(path))
        allow()

    if tool == "Bash":
        bad = check_bash(tool_input.get("command", ""), root)
        if bad:
            deny("scope_guard: dangerous bash denied: " + bad)
        allow()

    allow()


if __name__ == "__main__":
    main()
