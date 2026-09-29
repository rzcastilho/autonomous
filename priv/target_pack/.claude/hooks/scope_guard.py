#!/usr/bin/env python3
"""PreToolUse scope guard for orchestrator-driven and human worktrees.

Pack contract 3 (contract 2: feature 030; 3: AUTONOMOUS_* env markers). Decision order:

  1. Unparseable stdin -> deny, every origin, every profile.
  2. Resolve origin from the environment:
       AUTONOMOUS_ORCHESTRATED == "1" -> orchestrated; profile from
         AUTONOMOUS_CONTAINMENT_PROFILE (anything but "strict"/"permissive" -> strict).
       else CLAUDE_CODE_ENTRYPOINT == "cli" -> interactive (human), no denial.
       else -> undecided -> strict.
  3. profile == "permissive" -> allow. No rule list (no floor).
  4. profile == "strict" -> apply the strict rule set below; first match denies.

Deny output: Claude Code hook JSON with permissionDecision "deny", reason
"scope_guard[<profile>|<origin>]: <rule_id>: <detail>".
"""

import sys
import os
import re
import json

PACK_CONTRACT = 3

FILE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
PROFILES = {"strict", "permissive"}
HUMAN_ENTRYPOINTS = {"cli"}

# (rule_id, pattern, detail) — checked in order, first match wins.
DANGEROUS_BASH = [
    ("bash_rm_rf_root", r"\brm\s+-rf\s+/(?:\s|$)", "rm -rf /"),
    ("bash_rm_rf_home", r"\brm\s+-rf\s+~", "rm -rf ~"),
    ("bash_sudo", r"\bsudo\b", "sudo"),
    ("bash_git_push", r"\bgit\s+push\b", "git push (the orchestrator owns git)"),
    ("bash_curl", r"^\s*curl\b", "curl"),
    ("bash_wget", r"^\s*wget\b", "wget"),
    ("bash_pipe_to_shell", r"(curl|wget)\b[^|]*\|\s*(?:sh|bash)", "curl/wget | sh"),
    ("bash_fork_bomb", r":\s*\(\s*\)\s*\{.*\|.*&\s*\}", "fork bomb"),
    ("bash_chmod_777_root", r"\bchmod\s+-R\s+777\s+/", "chmod -R 777 /"),
]


def deny(profile, origin, rule_id, detail):
    reason = "scope_guard[{}|{}]: {}: {}".format(profile, origin, rule_id, detail)
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


def resolve_origin_profile(env):
    if env.get("AUTONOMOUS_ORCHESTRATED") == "1":
        profile = env.get("AUTONOMOUS_CONTAINMENT_PROFILE")
        if profile not in PROFILES:
            profile = "strict"
        return "orchestrated", profile

    if env.get("CLAUDE_CODE_ENTRYPOINT") in HUMAN_ENTRYPOINTS:
        return "interactive", None

    return "undecided", "strict"


def check_file_tool(tool_input, root):
    for key in ("file_path", "notebook_path"):
        path = tool_input.get(key)
        if path is not None and not within(root, path):
            return "write_outside_worktree", "write outside worktree denied: " + str(path)
    return None


def check_bash(cmd, root):
    for rule_id, pattern, detail in DANGEROUS_BASH:
        if re.search(pattern, cmd):
            return rule_id, detail
    for match in re.finditer(r">>?\s*\"?(/[^\"\s]+)", cmd):
        target = match.group(1)
        if not within(root, target):
            return "bash_redirect_outside_worktree", "redirect outside worktree: " + target
    return None


def decide(origin, profile, tool, tool_input, root):
    """Returns None (allow) or (rule_id, detail) (deny)."""
    if origin == "interactive":
        return None

    # orchestrated or undecided; profile resolved to "strict" or "permissive"
    if profile == "permissive":
        return None

    if tool in FILE_TOOLS:
        return check_file_tool(tool_input, root)

    if tool == "Bash":
        return check_bash(tool_input.get("command", ""), root)

    if tool == "WebFetch":
        return "tool_web_fetch", "WebFetch denied under strict containment"

    if tool == "WebSearch":
        return "tool_web_search", "WebSearch denied under strict containment"

    return None


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--contract":
        print(PACK_CONTRACT)
        sys.exit(0)

    try:
        data = json.load(sys.stdin)
    except Exception:
        deny("unknown", "unknown", "unparseable", "unparseable hook input")
        return

    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    root = os.path.realpath(data.get("cwd") or os.getcwd())

    origin, profile = resolve_origin_profile(os.environ)

    if origin == "interactive":
        allow()
        return

    result = decide(origin, profile, tool, tool_input, root)
    if result is None:
        allow()
        return

    rule_id, detail = result
    deny(profile or "strict", origin, rule_id, detail)


if __name__ == "__main__":
    main()
