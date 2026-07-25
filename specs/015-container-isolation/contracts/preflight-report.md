# Contract: Preflight Report

**Feature**: `015-container-isolation` | Satisfies FR-032, FR-033, FR-034, FR-035.

The preflight report is the durable record produced before any feature work. It
is written whether preflight passes or fails, so an operator can diagnose a
refusal without entering the container.

**Location**: `<run_state_root>/preflight/<iso8601>-<status>.json`, with the
newest copied to `<run_state_root>/preflight/latest.json`. Pretty-printed JSON,
matching the repo's existing convention for process-generated JSON.

---

## 1. Schema

```json
{
  "status": "pass | warn | fail",
  "collected_at": "2026-07-24T21:03:11Z",
  "repo": "/home/alice/code/ledgerlite",
  "run_state_root": "/home/alice/.autonomous",
  "image": {
    "source_revision": "b17f0ea…",
    "orchestrator_version": "0.1.0",
    "image_ref": "ghcr.io/rzcastilho/autonomous:v0.1.0",
    "built_at": "2026-07-24T18:40:00Z",
    "elixir": "1.20.2",
    "otp": "28",
    "base_digests": { "builder": "sha256:…", "runtime": "sha256:…" },
    "tools": { "git": "2.39.5", "gh": "2.62.0", "claude": "…", "specify": "v0.12.11", "python3": "3.11.2", "mise": "…", "uv": "…" }
  },
  "resolved_versions": {
    "git": "2.39.5",
    "gh": "2.62.0",
    "claude": "…",
    "specify": "v0.12.11",
    "python3": "3.11.2",
    "mise": "…",
    "target_toolchain": "python 3.12.4"
  },
  "checks": [
    {
      "id": "tool_claude",
      "category": "tool",
      "status": "ok",
      "detail": "claude resolved on PATH",
      "expected": "…",
      "observed": "…",
      "fix": null
    },
    {
      "id": "run_state_durable",
      "category": "mount",
      "status": "fail",
      "detail": "/home/alice/.autonomous is not a mount point; run state would be lost when the container exits",
      "expected": "a bind mount at the identical host path",
      "observed": "path exists on the container's tmpfs $HOME",
      "fix": "add -v \"$HOME/.autonomous:$HOME/.autonomous\" to the run command"
    }
  ]
}
```

`image` is `null` when the release runs outside a container (development).
`resolved_versions.target_toolchain` is present only once a target toolchain has
been resolved via mise (SC-008).

---

## 2. Field rules

| Field | Rule |
|---|---|
| `status` | `fail` if any check is `fail`; else `warn` if any is `warn`; else `pass` |
| `checks` | Sorted by `category` then `id` — the same environment always yields byte-identical ordering |
| `fix` | Non-null **iff** `status != "ok"`. Enforced by a unit test over every emittable check (SC-007) |
| `detail` / `expected` / `observed` / `fix` | MUST NOT contain a credential value, prefix, suffix, or length (FR-035) |
| Credential checks | Record a **source** only: `"env"`, `"mounted_config"`, or `"absent"` |

---

## 3. Check inventory

| `id` | Category | `fail` condition | `warn` condition |
|---|---|---|---|
| `tool_git` | tool | absent from `PATH` | version differs from the image pin |
| `tool_gh` | tool | absent and PR workflow enabled | absent and PR workflow disabled |
| `tool_claude` | tool | absent, or `claude --help` non-zero | version differs from the image pin |
| `tool_specify` | tool | absent | version ≠ `SPECKIT_VERSION` |
| `tool_python3` | tool | absent (the scope-guard hook is invoked as `python3`) | — |
| `tool_mise` | tool | absent | — |
| `credential_agent` | credential | neither env auth nor mounted config present | — |
| `credential_gh` | credential | PR workflow on and `GH_TOKEN` absent | PR workflow off and absent |
| `repo_mounted` | mount | path missing, not a git work tree, or not writable | — |
| `repo_path_identity` | path_identity | `AUTONOMOUS_HOST_REPO ≠ SPECKIT_REPO` | assertion vars absent (non-container run) |
| `home_path_identity` | path_identity | `AUTONOMOUS_HOST_HOME ≠ $HOME` | assertion vars absent |
| `run_state_writable` | mount | resolved run-state root not writable | — |
| `run_state_durable` | mount | resolved run-state root is not a mount point | not a mount point **and** not containerized |
| `target_pack` | target_repo | `TargetPack.verify/1` returns an error | — |
| `image_identity` | runtime | `/etc/autonomous/image.json` unreadable while containerized | absent while not containerized |
| `unprivileged` | runtime | effective UID is 0 | — |

---

## 4. Behavioural contract

| Report status | Auto-start | Container |
|---|---|---|
| `pass` | run launches | stays up |
| `warn` | run launches; warnings logged at `:warning` | stays up |
| `fail` | **no run launches**, no agent spend | stays up **idle**; failure visible in logs and console; no success reported (FR-031) |

---

## 5. Elixir surface

```elixir
@spec collect(keyword()) :: map()                    # IO — probes the environment
@spec evaluate(map()) :: Preflight.Report.t()        # pure — no IO
@spec persist(Preflight.Report.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
@spec run(keyword()) :: {:ok, Report.t()} | {:error, Report.t()}
```

`collect/1` accepts injected probe seams (tool lookup, mountinfo contents, file
stat, `TargetPack.verify/1`) so the hermetic suite exercises every failure mode
with no container and no CLI — the same injected-seam discipline the constitution
already requires for wave/DAG/breaker logic.
