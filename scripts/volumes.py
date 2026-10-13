#!/usr/bin/env python3
"""User-defined persistent volumes (feature 041): declaration parsing and planning.

Host-side only, stdlib only. Called by scripts/autonomous; never mounted into a
container. Contracts: specs/041-user-defined-volumes/contracts/.

  volumes.py plan|show|init|select ...
"""
import argparse
import json
import os
import posixpath
import re
import sys

MIN_PYTHON = (3, 11)

EXIT_USAGE = 2

# --- reserved variable names (research.md R9) --------------------------------

RESERVED_PREFIXES = ("AUTONOMOUS_", "RELEASE_")

RESERVED_VARIABLES = (
    "PATH",
    "HOME",
    "SHELL",
    "USER",
    "MIX_ENV",
    "PHX_SERVER",
    "COMPOSE_PROJECT_NAME",
    "DISPLAY",
    "GH_TOKEN",
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "CLAUDE_CONFIG_DIR",
    "MISE_TRUSTED_CONFIG_PATHS",
    "MISE_YES",
)

# Image-set variables an entry may override despite living under a reserved
# prefix or list (FR-008b). Toolchain locations are not reserved at all.
ALLOWED_IMAGE_OVERRIDES = (
    "MISE_DATA_DIR",
    "MIX_HOME",
    "HEX_HOME",
    "PLAYWRIGHT_BROWSERS_PATH",
)

# --- protected paths (data-model.md "Protected paths") ------------------------

STATE_ROOT_DEFAULT = "/home/autonomous/.autonomous"

STATIC_PROTECTED = (
    "/workspace",
    "/workspace/_build",
    "/workspace/deps",  # redundant with /workspace; kept so violations name it
    "/app",
    "/home/autonomous/.claude",
    "/home/autonomous/.claude.json",
    "/home/autonomous/.claude.host.json",
)

# --- docker naming and labels (research.md R4) --------------------------------

LABEL_KIND = "dev.autonomous.kind"
LABEL_SEGMENT = "dev.autonomous.segment"
LABEL_VOLUME = "dev.autonomous.volume"
KIND_USER_VOLUME = "user-volume"


class Malformed(Exception):
    """The declaration cannot be read as a volume declaration (FR-010)."""


def volume_name(segment, name):
    return f"autonomous-{segment}_vol-{name}"


def volume_labels(segment, name):
    return {
        LABEL_KIND: KIND_USER_VOLUME,
        LABEL_SEGMENT: segment,
        LABEL_VOLUME: name,
    }


STATIC_LABELS = {
    "/workspace": "orchestrator source",
    "/workspace/_build": "orchestrator build",
    "/workspace/deps": "orchestrator dependencies",
    "/app": "application install",
    "/home/autonomous/.claude": "agent configuration",
    "/home/autonomous/.claude.json": "agent configuration",
    "/home/autonomous/.claude.host.json": "agent configuration",
}


def protected_labelled(ctx):
    """(path, label) pairs protected for one instance; ctx supplies the dynamic ones."""
    dynamic = [
        (ctx.get("repo"), "target repository"),
        (ctx.get("worktree_root"), "worktree root"),
        (ctx.get("state_root") or STATE_ROOT_DEFAULT, "orchestrator state root"),
    ]
    return [(p, label) for p, label in dynamic if p] + [
        (p, STATIC_LABELS[p]) for p in STATIC_PROTECTED
    ]


def protected_paths(ctx):
    """Protected container paths for one instance."""
    return [p for p, _ in protected_labelled(ctx)]


def check_python():
    """Refuse by name when tomllib is unavailable."""
    if sys.version_info < MIN_PYTHON:
        found = ".".join(str(n) for n in sys.version_info[:3])
        return f"python3 >= {MIN_PYTHON[0]}.{MIN_PYTHON[1]} (tomllib); found {found}"
    return None


# --- parse --------------------------------------------------------------------


def parse(text, path="volumes.toml"):
    """Return the declared entries (dicts, declaration order) or raise Malformed."""
    import tomllib

    try:
        doc = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise Malformed(f"{path}: not valid TOML: {e}") from None

    stray = sorted(k for k in doc if k != "volume")
    if stray:
        raise Malformed(
            f"{path}: not valid TOML: unexpected top-level key {stray[0]!r} "
            "(only [[volume]] entries are allowed)"
        )

    entries = doc.get("volume", [])
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        raise Malformed(f"{path}: not valid TOML: 'volume' must be an array of tables")
    return entries


# --- validate ------------------------------------------------------------------

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VAR_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ENTRY_KEYS = ("name", "path", "env", "path_dirs")
NAME_MAX = 63


def violation(entry, field, reason):
    return {"entry": entry, "field": field, "reason": reason}


def entry_label(entry, index):
    name = entry.get("name")
    if isinstance(name, str) and NAME_RE.match(name) and len(name) <= NAME_MAX:
        return name
    return f"#{index}"


def inside(path, root):
    """True when path equals root or lies below it."""
    return path == root or path.startswith(root.rstrip("/") + "/")


def bad_chars(value):
    return any(c in ":," or ord(c) < 32 or ord(c) == 127 for c in value)


def path_problem(value):
    """Why `value` is not an acceptable absolute normalized path, or None."""
    if not isinstance(value, str) or not value:
        return "must be a non-empty string"
    if not value.startswith("/"):
        return f"{value} is not absolute"
    if bad_chars(value):
        return f"{value!r} contains a forbidden character (':', ',' or a control character)"
    if value != "/" and (value != posixpath.normpath(value) or value.endswith("/")):
        return f"{value} is not normalized (no '.', '..', '//' or trailing '/')"
    return None


def name_violations(entries):
    """Name rules only; these also gate reset-cache (research.md R11 step 3)."""
    out = []
    seen = {}
    for i, entry in enumerate(entries, 1):
        label = entry_label(entry, i)
        name = entry.get("name")
        if not isinstance(name, str):
            out.append(violation(label, "name", "name is required and must be a string"))
            continue
        if len(name) > NAME_MAX or not NAME_RE.match(name):
            out.append(
                violation(
                    label,
                    "name",
                    f"name {name!r} must be a lowercase slug (a-z, 0-9, '-', starting with "
                    f"a letter or digit, at most {NAME_MAX} characters)",
                )
            )
            continue
        seen[name] = seen.get(name, 0) + 1
        if seen[name] == 2:
            out.append(violation(name, "name", "name is declared more than once"))
    return out


def reserved_reason(var):
    if var in ALLOWED_IMAGE_OVERRIDES:
        return None
    if var.startswith(RESERVED_PREFIXES):
        return f"{var} is reserved (the {var.split('_')[0]}_ prefix belongs to the orchestrator)"
    if var in RESERVED_VARIABLES:
        return f"{var} is reserved (set by the start sequence)"
    return None


def validate(entries, ctx):
    """Return every violation ({entry, field, reason}); empty when valid (FR-009)."""
    out = name_violations(entries)
    protected = protected_labelled(ctx)
    labels = [entry_label(e, i) for i, e in enumerate(entries, 1)]
    valid_paths = {}
    setters = {}

    for i, entry in enumerate(entries, 1):
        label = labels[i - 1]
        for key in sorted(k for k in entry if k not in ENTRY_KEYS):
            out.append(violation(label, key, f"unknown key {key!r}"))

        path = entry.get("path")
        if "path" not in entry:
            out.append(violation(label, "path", "path is required"))
        else:
            problem = path_problem(path)
            if problem:
                out.append(violation(label, "path", f"path {problem}"))
            else:
                valid_paths[label] = (i, path)
                for prot, what in protected:
                    if inside(path, prot):
                        out.append(
                            violation(label, "path", f"path {path} is inside {prot} ({what})")
                        )
                    elif inside(prot, path):
                        out.append(
                            violation(label, "path", f"path {path} contains {prot} ({what})")
                        )

        env = entry.get("env", {})
        if not isinstance(env, dict):
            out.append(violation(label, "env", "env must be a table of string values"))
        else:
            for var, value in env.items():
                if not VAR_RE.match(var):
                    out.append(violation(label, "env", f"variable name {var!r} is not valid"))
                    continue
                reason = reserved_reason(var)
                if reason:
                    out.append(violation(label, "env", reason))
                if not isinstance(value, str) or "\0" in value or "\n" in value or "\r" in value:
                    out.append(
                        violation(
                            label,
                            "env",
                            f"{var} must be a string without NUL or newline characters",
                        )
                    )
                setters.setdefault(var, []).append(label)

        dirs = entry.get("path_dirs", [])
        if not isinstance(dirs, list):
            out.append(violation(label, "path_dirs", "path_dirs must be a list of paths"))
        else:
            for d in dirs:
                problem = path_problem(d)
                if problem:
                    out.append(violation(label, "path_dirs", f"path_dirs entry {problem}"))
                elif label in valid_paths and not inside(d, valid_paths[label][1]):
                    out.append(
                        violation(
                            label,
                            "path_dirs",
                            f"path_dirs entry {d} is outside the entry's own path "
                            f"{valid_paths[label][1]}",
                        )
                    )

    for var, who in setters.items():
        distinct = list(dict.fromkeys(who))
        if len(distinct) > 1:
            out.append(violation(distinct, "env", f"both set {var}"))

    items = list(valid_paths.items())
    for a in range(len(items)):
        for b in range(a + 1, len(items)):
            (la, (_, pa)), (lb, (_, pb)) = items[a], items[b]
            if inside(pa, pb) or inside(pb, pa):
                what = "the same path" if pa == pb else "nested paths"
                out.append(violation([la, lb], "path", f"{what} ({pa} and {pb})"))
    return out


def render_violations(path, violations):
    """Violation lines per contracts/declaration-format.md "Validation output"."""
    n = len(violations)
    lines = [f"autonomous: {path}: {n} problem{'' if n == 1 else 's'}"]
    for v in violations:
        who = v["entry"]
        if isinstance(who, (list, tuple)):
            lines.append(f"autonomous:   entries {', '.join(who)}: {v['reason']}")
        else:
            lines.append(f"autonomous:   entry {who}: {v['reason']}")
    lines.append("autonomous: nothing was started; fix the declaration and retry")
    return "\n".join(lines)


# --- plan ---------------------------------------------------------------------

SERVICES = ("dev", "console", "release")


def image_env_map(image_env):
    """The image's environment as a dict, from a ["K=V", ...] list or a dict."""
    if isinstance(image_env, dict):
        return dict(image_env)
    out = {}
    for item in image_env or []:
        key, _, value = item.partition("=")
        out[key] = value
    return out


def plan(entries, ctx, declaration=""):
    """Normalise the entries and render everything the wrapper applies."""
    segment = ctx["segment"]
    image_env = image_env_map(ctx.get("image_env"))

    volumes = []
    notices = []
    for entry in entries:
        env = [[k, v] for k, v in (entry.get("env") or {}).items()]
        volumes.append(
            {
                "name": entry["name"],
                "path": entry["path"],
                "docker_name": volume_name(segment, entry["name"]),
                "env": env,
                "path_dirs": list(entry.get("path_dirs") or []),
            }
        )
        for key, value in env:
            if key in image_env:
                notices.append(
                    f"volume {entry['name']}: {key} overrides image value "
                    f"{image_env[key]} with {value}"
                )

    result = {"volumes": volumes, "notices": notices}
    if volumes:
        result["overlay"] = overlay(volumes, image_env, declaration)
    return result


def overlay(volumes, image_env, declaration):
    """The Compose overlay (contracts/applied-volumes.md)."""
    path_dirs = [d for v in volumes for d in v["path_dirs"]]

    environment = {}
    for v in volumes:
        for key, value in v["env"]:
            environment[key] = value
    if path_dirs:
        image_path = image_env.get("PATH")
        environment["PATH"] = ":".join(path_dirs + ([image_path] if image_path else []))
    applied = {
        "version": 1,
        "declaration": declaration,
        "volumes": [
            {"name": v["name"], "path": v["path"], "env": v["env"], "path_dirs": v["path_dirs"]}
            for v in volumes
        ],
    }
    environment["AUTONOMOUS_VOLUMES"] = json.dumps(applied, separators=(",", ":"))
    if path_dirs:
        environment["AUTONOMOUS_VOLUME_PATH"] = ":".join(path_dirs)

    mounts = [{"type": "volume", "source": f"vol-{v['name']}", "target": v["path"]} for v in volumes]
    return {
        "services": {
            svc: {"volumes": [dict(m) for m in mounts], "environment": dict(environment)}
            for svc in SERVICES
        },
        "volumes": {
            f"vol-{v['name']}": {"external": True, "name": v["docker_name"]} for v in volumes
        },
    }


def write_private(path, text):
    """Atomic write, mode 0600, parent directory 0700 when created."""
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


# --- starter ------------------------------------------------------------------


def starter():
    """The commented starter file written by `volumes --init` (no active entries)."""
    reserved = ", ".join(RESERVED_VARIABLES)
    return f"""\
# Persistent volumes for this target (autonomous feature 041).
#
# This file lives on the host only. It is never mounted into a container, so
# agent sessions cannot read or edit it. Each [[volume]] becomes a named Docker
# volume for this target; it survives stop/start and image rebuilds.
#
# Rules (every violation is reported and nothing starts until all are fixed):
#   name       lowercase slug (a-z, 0-9, '-'), at most 63 characters, unique
#   path       absolute container path, normalized; not the target repo, the
#              worktree root, the state root, /workspace, /app or the agent
#              configuration; entries may not nest inside one another
#   env        optional table of variables set for every session; values are
#              literal strings (no $VAR expansion); one entry per variable
#   path_dirs  optional absolute directories inside this entry's path, put in
#              front of PATH in declaration order
#
# Reserved variables (refused): AUTONOMOUS_*, RELEASE_*, {reserved}
#
# Put mounts under /var/lib/autonomous/volumes/<name>. Use `scripts/autonomous
# reset-cache --target <repo>` to empty volumes, `stop --purge` to remove them.

# --- Rust ---------------------------------------------------------------------
# [[volume]]
# name = "rust-toolchains"
# path = "/var/lib/autonomous/volumes/rust-toolchains"
# path_dirs = ["/var/lib/autonomous/volumes/rust-toolchains/cargo/bin"]
# [volume.env]
# RUSTUP_HOME = "/var/lib/autonomous/volumes/rust-toolchains/rustup"
# CARGO_HOME = "/var/lib/autonomous/volumes/rust-toolchains/cargo"
#
# [[volume]]
# name = "cargo-target"
# path = "/var/lib/autonomous/volumes/cargo-target"
# env = {{ CARGO_TARGET_DIR = "/var/lib/autonomous/volumes/cargo-target" }}

# --- Node + pnpm --------------------------------------------------------------
# [[volume]]
# name = "pnpm-store"
# path = "/var/lib/autonomous/volumes/pnpm-store"
# path_dirs = ["/var/lib/autonomous/volumes/pnpm-store/bin"]
# [volume.env]
# PNPM_HOME = "/var/lib/autonomous/volumes/pnpm-store/bin"
# npm_config_store_dir = "/var/lib/autonomous/volumes/pnpm-store/store"

# --- Elixir -------------------------------------------------------------------
# [[volume]]
# name = "mix-build"
# path = "/var/lib/autonomous/volumes/mix-build"
# [volume.env]
# MIX_BUILD_PATH = "/var/lib/autonomous/volumes/mix-build/_build"
# MIX_DEPS_PATH = "/var/lib/autonomous/volumes/mix-build/deps"

# --- Python -------------------------------------------------------------------
# [[volume]]
# name = "python-env"
# path = "/var/lib/autonomous/volumes/python-env"
# path_dirs = ["/var/lib/autonomous/volumes/python-env/venv/bin"]
# [volume.env]
# VIRTUAL_ENV = "/var/lib/autonomous/volumes/python-env/venv"
# PIP_CACHE_DIR = "/var/lib/autonomous/volumes/python-env/pip-cache"
"""


# --- select -------------------------------------------------------------------


def select(entries, names):
    """Declared volume names to reset, in declaration order (research.md R11).

    Returns (selected, unknown). No names selects every declared volume.
    """
    declared = [e["name"] for e in entries]
    if not names:
        return declared, []
    unknown = [n for n in names if n not in declared]
    return [n for n in declared if n in names], unknown


# --- CLI ----------------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(prog="volumes.py", description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("plan", "show", "init", "select"):
        sp = sub.add_parser(name)
        sp.add_argument("--declaration", required=True, help="path of volumes.toml")
        if name in ("plan", "show"):
            sp.add_argument("--context", default="{}", help="instance context (JSON)")
        if name == "plan":
            sp.add_argument("--write-overlay", help="write the Compose overlay to this path")
            sp.add_argument(
                "--records",
                action="store_true",
                help="print tab-separated records for the wrapper instead of JSON",
            )
        if name == "show":
            sp.add_argument("--present", default="[]", help="JSON list of present docker volume names")
        if name == "select":
            sp.add_argument("--volume", action="append", default=[])
    return p


def load_entries(path):
    """Entries of the declaration at `path`; a missing file declares nothing."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return parse(f.read(), path)


def cmd_plan(args):
    ctx = json.loads(args.context)
    entries = load_entries(args.declaration)
    violations = validate(entries, ctx)
    if violations:
        print(render_violations(args.declaration, violations), file=sys.stderr)
        return EXIT_USAGE
    result = plan(entries, ctx, args.declaration)
    if args.write_overlay and "overlay" in result:
        write_private(args.write_overlay, json.dumps(result["overlay"], indent=2) + "\n")
    if args.records:
        print_records(result)
    else:
        print(json.dumps(result))
    return 0


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def print_records(result):
    """Tab-separated records for the shell wrapper (it never parses JSON)."""
    for v in result["volumes"]:
        print(
            "\t".join(
                [
                    "volume",
                    v["name"],
                    v["docker_name"],
                    v["path"],
                    plural(len(v["env"]), "variable"),
                    plural(len(v["path_dirs"]), "path dir"),
                ]
            )
        )
    for notice in result["notices"]:
        print(f"notice\t{notice}")


def cmd_select(args):
    entries = load_entries(args.declaration)
    problems = name_violations(entries)
    if problems:
        print(render_violations(args.declaration, problems), file=sys.stderr)
        return EXIT_USAGE
    selected, unknown = select(entries, args.volume)
    if unknown:
        declared = ", ".join(e["name"] for e in entries) or "none"
        for n in unknown:
            print(f"autonomous: volume {n} is not declared; declared: {declared}", file=sys.stderr)
        return EXIT_USAGE
    for n in selected:
        print(n)
    return 0


def cmd_init(args):
    if os.path.exists(args.declaration):
        print(f"autonomous: {args.declaration} already exists; not changed")
        return 1
    write_private(args.declaration, starter())
    print(f"autonomous: wrote {args.declaration}")
    return 0


def cmd_show(args):
    ctx = json.loads(args.context)
    path = args.declaration
    if not os.path.exists(path):
        print(f"autonomous: declaration {path}")
        print("autonomous: no declaration (create one with --init)")
        return 0
    entries = load_entries(path)
    present = set(json.loads(args.present))
    segment = ctx.get("segment", "")
    print(f"autonomous: declaration {path}")
    declared = set()
    for e in entries:
        name = str(e.get("name", "?"))
        docker = volume_name(segment, name)
        declared.add(docker)
        state = "present" if docker in present else "absent"
        print(f"autonomous: volume {name}  {e.get('path', '?')}  {state}")
        for key, value in (e.get("env") or {}).items():
            print(f"autonomous:   {key}={value}")
        for d in e.get("path_dirs") or []:
            print(f"autonomous:   PATH += {d}")
    for docker in sorted(present - declared):
        short = docker.split("_vol-", 1)[-1]
        print(
            f"autonomous: volume {short}  kept, not declared — "
            f"remove with: docker volume rm {docker}"
        )
    violations = validate(entries, ctx)
    if violations:
        print(render_violations(path, violations))
        return EXIT_USAGE
    n = len(entries)
    print(f"autonomous: declaration valid ({n} volume{'' if n == 1 else 's'})")
    return 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    problem = check_python()
    if problem:
        where = getattr(args, "declaration", None) or sys.argv[0]
        print(f"autonomous: {where} needs {problem}", file=sys.stderr)
        return EXIT_USAGE
    try:
        if args.command == "plan":
            return cmd_plan(args)
        if args.command == "init":
            return cmd_init(args)
        if args.command == "show":
            return cmd_show(args)
        if args.command == "select":
            return cmd_select(args)
    except Malformed as e:
        print(f"autonomous: {e}", file=sys.stderr)
        return EXIT_USAGE
    print(f"autonomous: volumes {args.command}: not implemented yet", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
