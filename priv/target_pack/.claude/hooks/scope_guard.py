#!/usr/bin/env python3
"""PreToolUse scope guard for orchestrator-driven and human worktrees.

Pack contract 5 (contract 2: feature 030; 3: AUTONOMOUS_* env markers;
4: settings.json env shell timeouts (feature 032); 5: strict package-manager
exception for sudo, feature 037). Decision order:

  1. Unparseable stdin -> deny, every origin, every profile.
  2. Resolve origin from the environment:
       AUTONOMOUS_ORCHESTRATED == "1" -> orchestrated; profile from
         AUTONOMOUS_CONTAINMENT_PROFILE (anything but "strict"/"permissive" -> strict).
       else CLAUDE_CODE_ENTRYPOINT == "cli" -> interactive (human), no denial.
       else -> undecided -> strict.
  3. profile == "permissive" -> allow. No rule list (no floor).
  4. profile == "strict" -> apply the strict rule set below; first match denies.
     The `bash_sudo` rule is skipped only when AUTONOMOUS_CONTAINER == "1" and
     AUTONOMOUS_AGENT_ROOT == "1" and every sudo segment is an apt-get/apt
     update|install or a dpkg/apt query (see sudo_allowed).

Deny output: Claude Code hook JSON with permissionDecision "deny", reason
"scope_guard[<profile>|<origin>]: <rule_id>: <detail>".
"""

import sys
import os
import re
import json
import shlex

PACK_CONTRACT = 5

FILE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
PROFILES = {"strict", "permissive"}
HUMAN_ENTRYPOINTS = {"cli"}

# Redirect targets that are device files, not paths in or out of the worktree
# (feature 031, FR-027). Exact match only: /dev/nullx, /dev/sda and
# /dev/null/../x are still checked by within().
DEVICE_SINKS = {"/dev/null", "/dev/stdout", "/dev/stderr"}

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


SUDO_SEPARATORS = {"&&", "||", ";", "|", "&"}
APT_INSTALL_OPTS = {"-y", "--yes", "--assume-yes", "-q", "-qq", "--quiet",
                    "--no-install-recommends"}
APT_QUERY_OPTS = {"--installed", "--upgradable", "--all-versions"}
DPKG_QUERY_FLAGS = {"-l", "--list", "-s", "--status", "-L", "--listfiles",
                    "-S", "--search", "--get-selections"}
PKG_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+)?$")
SUDO_WORD_RE = re.compile(r"\bsudo\b")
AGENT_ROOT_DETAIL = "sudo (agent root allows only apt-get/apt update|install and dpkg queries)"


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


def agent_root_active(env):
    return env.get("AUTONOMOUS_CONTAINER") == "1" and env.get("AUTONOMOUS_AGENT_ROOT") == "1"


def split_unquoted_newlines(cmd):
    """Replace unquoted newlines with `;` so they separate segments."""
    out = []
    quote = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"' and i + 1 < len(cmd):
                out.append(c)
                i += 1
                c = cmd[i]
        elif c in ("'", '"'):
            quote = c
        elif c == "\\" and i + 1 < len(cmd):
            out.append(c)
            i += 1
            c = cmd[i]
        elif c == "\n":
            c = " ; "
        out.append(c)
        i += 1
    return "".join(out)


def is_redirect(tok):
    return ">" in tok and all(ch in ">&" for ch in tok)


def sudo_segment_allowed(seg):
    """seg[0] == "sudo". True only for the closed package-manager grammar."""
    i = 1
    if i < len(seg) and seg[i] == "-n":
        i += 1
    if i < len(seg) and seg[i] == "DEBIAN_FRONTEND=noninteractive":
        i += 1
    if i >= len(seg):
        return False
    pm, rest = seg[i], seg[i + 1:]
    if pm in ("apt-get", "apt"):
        if not rest:
            return False
        action, args = rest[0], rest[1:]
        if action == "update":
            return all(a in APT_INSTALL_OPTS for a in args)
        if action == "install":
            pkgs = 0
            for a in args:
                if a in APT_INSTALL_OPTS:
                    continue
                if PKG_RE.match(a):
                    pkgs += 1
                    continue
                return False
            return pkgs > 0
        if pm == "apt" and action in ("list", "show", "policy"):
            return all(
                a in APT_INSTALL_OPTS or a in APT_QUERY_OPTS
                or (not a.startswith("-") and "/" not in a)
                for a in args
            )
        return False
    if pm == "dpkg":
        if not rest or rest[0] not in DPKG_QUERY_FLAGS:
            return False
        return all(not a.startswith("-") and "/" not in a for a in rest[1:])
    return False


def sudo_allowed(cmd):
    """True when every sudo in cmd is an allowed package-manager call."""
    if any(m in cmd for m in ("`", "$(", "<(", ">(")):
        return False
    try:
        lex = shlex.shlex(split_unquoted_newlines(cmd), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return False

    segments, cur = [], []
    for tok in tokens:
        if tok in SUDO_SEPARATORS:
            segments.append(cur)
            cur = []
        elif tok.strip("();<>|&") == "" and not is_redirect(tok):
            return False  # parens, heredoc/input redirects, ;; and friends
        else:
            cur.append(tok)
    segments.append(cur)

    for seg in segments:
        for idx, tok in enumerate(seg):
            if SUDO_WORD_RE.search(tok) and not (idx == 0 and tok == "sudo"):
                return False
        if seg and seg[0] == "sudo":
            # drop redirects (and their targets); the redirect rule judges them
            plain, skip = [], False
            for tok in seg:
                if skip:
                    skip = False
                elif is_redirect(tok):
                    skip = True
                    if len(plain) > 1 and plain[-1].isdigit():
                        plain.pop()
                else:
                    plain.append(tok)
            if not sudo_segment_allowed(plain):
                return False
    return True


def check_bash(cmd, root, agent_root=False):
    for rule_id, pattern, detail in DANGEROUS_BASH:
        if rule_id == "bash_sudo" and agent_root:
            if not re.search(pattern, cmd) or sudo_allowed(cmd):
                continue
            return rule_id, AGENT_ROOT_DETAIL
        if re.search(pattern, cmd):
            return rule_id, detail
    for match in re.finditer(r">>?\s*\"?(/[^\"\s]+)", cmd):
        target = match.group(1)
        if target in DEVICE_SINKS:
            continue
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
        return check_bash(tool_input.get("command", ""), root, agent_root_active(os.environ))

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
