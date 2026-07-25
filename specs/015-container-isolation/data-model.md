# Data Model: Container Isolation for Autonomous Runs

**Feature**: `015-container-isolation` | **Date**: 2026-07-24

Entities introduced by this feature. Every one is a plain Elixir struct built at
the IO boundary and consumed by pure functions (Constitution I / VI). No
database — state is file-backed, consistent with the Technology Stack section of
the constitution.

---

## 1. `SpeckitOrchestrator.ImageInfo`

The image's self-identification (FR-007), read from `/etc/autonomous/image.json`
which is written into the runtime stage at build time.

| Field | Type | Source | Notes |
|---|---|---|---|
| `source_revision` | `String.t()` | build arg | Full git SHA of the source the image was built from |
| `orchestrator_version` | `String.t()` | `mix.exs` `:version` | e.g. `"0.1.0"` |
| `image_ref` | `String.t()` | build arg | `ghcr.io/rzcastilho/autonomous:v<semver>` |
| `built_at` | `DateTime.t()` | build arg | RFC3339, UTC |
| `tools` | `%{String.t() => String.t()}` | build stage probes | `%{"git" => "2.39.5", "gh" => "2.x.y", "claude" => "…", "specify" => "v0.12.11", "python3" => "3.11.2", "mise" => "…", "uv" => "…"}` |
| `elixir` | `String.t()` | builder stage | `"1.20.2"` |
| `otp` | `String.t()` | builder stage | `"28"` |
| `base_digests` | `%{String.t() => String.t()}` | build args | `%{"builder" => "sha256:…", "runtime" => "sha256:…"}` |

**Validation**

- Every field is required. A missing or unparseable `/etc/autonomous/image.json`
  is **not** fatal on its own (the release may be run outside a container during
  development) but produces `{:error, :not_containerized}`, which preflight
  records as such rather than inventing values (Constitution II).
- `tools` MUST be non-empty in a containerized run; an empty map fails preflight.

**Lifecycle**: immutable. Read once at boot, cached in the preflight report.

---

## 2. `SpeckitOrchestrator.Preflight.Check`

One verified environment fact (FR-032).

| Field | Type | Notes |
|---|---|---|
| `id` | `atom()` | Stable identifier, e.g. `:tool_claude`, `:repo_mounted`, `:run_state_durable` |
| `category` | `:tool \| :credential \| :mount \| :target_repo \| :path_identity \| :runtime` | Groups the report |
| `status` | `:ok \| :warn \| :fail` | |
| `detail` | `String.t()` | Human-readable observed state. **Never** contains a credential value (FR-035) |
| `expected` | `String.t() \| nil` | What was required, e.g. a pinned version |
| `observed` | `String.t() \| nil` | What was found, e.g. the resolved version |
| `fix` | `String.t() \| nil` | The single action that resolves a `:warn`/`:fail` (FR-033). `nil` iff `status == :ok` |

**Validation**

- `status != :ok` ⇒ `fix` is present and non-empty. Enforced by a unit test over
  every check the collector can emit (SC-007).
- `detail`, `expected`, `observed`, and `fix` are screened against the
  credential env-var name set; a check that would embed a secret value records
  its **source** (`:env`, `:mounted_config`, `:absent`) instead.

**Check set** (the FR-032 list, expanded):

| `id` | Category | Fails when |
|---|---|---|
| `:tool_git`, `:tool_gh`, `:tool_claude`, `:tool_specify`, `:tool_python3`, `:tool_mise` | `:tool` | Absent from `PATH`, or version mismatches the pin recorded in `ImageInfo` |
| `:credential_agent` | `:credential` | Neither an auth env var nor a mounted agent config is present |
| `:credential_gh` | `:credential` | PR workflow enabled and `GH_TOKEN` absent (warn otherwise) |
| `:repo_mounted` | `:mount` | `SPECKIT_REPO` missing, not a git work tree, or not writable |
| `:repo_path_identity` | `:path_identity` | `AUTONOMOUS_HOST_REPO != SPECKIT_REPO` (FR-018) |
| `:home_path_identity` | `:path_identity` | `AUTONOMOUS_HOST_HOME != $HOME` (FR-019) |
| `:run_state_writable` | `:mount` | `Config.autonomous_root/0` not writable |
| `:run_state_durable` | `:mount` | Resolved run-state root is not a mount point (`:fail`), per FR-023 |
| `:target_pack` | `:target_repo` | `TargetPack.verify/1` returns an error (template constitution marker, uncommitted scaffold, missing hook) |
| `:image_identity` | `:runtime` | `/etc/autonomous/image.json` unreadable in a containerized run |
| `:unprivileged` | `:runtime` | Effective UID is 0 (FR-011) |

---

## 3. `SpeckitOrchestrator.Preflight.Report`

The aggregate persisted before any spend (FR-034, "Environment preflight report"
in the spec's Key Entities).

| Field | Type | Notes |
|---|---|---|
| `status` | `:pass \| :warn \| :fail` | Derived: `:fail` if any check fails, else `:warn` if any warns, else `:pass` |
| `checks` | `[Check.t()]` | Ordered by category then id, deterministic |
| `image` | `ImageInfo.t() \| nil` | `nil` outside a container |
| `resolved_versions` | `%{String.t() => String.t()}` | Tool + runtime versions actually resolved at preflight time (FR-034, SC-008) |
| `run_state_root` | `String.t()` | Resolved `Config.autonomous_root/0` |
| `repo` | `String.t()` | Resolved `Config.repo/0` |
| `collected_at` | `DateTime.t()` | |

**Derivation is pure**: `Preflight.evaluate(facts) :: Report.t()` takes a
collected-facts map and returns the report with no IO, so every failure mode is
unit-tested without a container (Constitution I, and the injected-seam discipline
the constitution already requires for wave/DAG/breaker logic).

**Persistence**: written as pretty-printed JSON to
`<run_state_root>/preflight/<iso8601>-<status>.json`, and the newest one
symlinked/copied to `<run_state_root>/preflight/latest.json`. Pretty-printed to
match the repo's existing "pretty-print all process-generated JSON" convention.

**State transitions**

```
collect ──▶ evaluate ──▶ :pass ──▶ persist ──▶ (auto-start may proceed)
                     └─▶ :warn ──▶ persist ──▶ (auto-start proceeds; warnings logged)
                     └─▶ :fail ──▶ persist ──▶ (no run starts; container stays idle — FR-031)
```

---

## 4. `SpeckitOrchestrator.Container.Env`

The parsed, validated view of the boot environment (FR-020). Not persisted — it
is the intermediate between raw `System.get_env/1` and
`Application.put_env/3` inside `config/runtime.exs` plus `Boot`.

| Field | Type | Env var | Required |
|---|---|---|---|
| `repo` | `String.t()` | `SPECKIT_REPO` | yes |
| `host_repo` | `String.t()` | `AUTONOMOUS_HOST_REPO` | in-container |
| `host_home` | `String.t()` | `AUTONOMOUS_HOST_HOME` | in-container |
| `autonomous_root` | `String.t()` | `AUTONOMOUS_ROOT` | no (`~/.autonomous`) |
| `specs_root` | `String.t()` | `SPECKIT_SPECS_ROOT` | no |
| `max_concurrency` | `pos_integer()` | `SPECKIT_MAX_CONCURRENCY` | no |
| `budget_usd` | `float()` | `SPECKIT_BUDGET_USD` | no |
| `implement_max_turns` | `pos_integer()` | `SPECKIT_IMPLEMENT_MAX_TURNS` | no |
| `phase_max_retries` | `non_neg_integer()` | `SPECKIT_PHASE_MAX_RETRIES` | no |
| `plan_stack` | `[String.t()]` | `SPECKIT_PLAN_STACK` | no |
| `models` | `%{atom() => String.t()}` | `SPECKIT_MODEL_<PHASE>` | no |
| `pr_workflow?` | `boolean()` | `SPECKIT_PR_WORKFLOW` | no |
| `pr_base` / `pr_remote` | `String.t()` | `SPECKIT_PR_BASE` / `SPECKIT_PR_REMOTE` | no |
| `speckit_version` | `String.t()` | `SPECKIT_VERSION` | no |
| `console_ip` / `console_port` | `:inet.ip_address()` / `pos_integer()` | `AUTONOMOUS_CONSOLE_IP` / `AUTONOMOUS_CONSOLE_PORT` | no |
| `autostart` | `autostart()` | `AUTONOMOUS_AUTOSTART` | no |

**`autostart()`**: `:none | {:breakdown, slug :: String.t()} | :ad_hoc`.
`AUTONOMOUS_AUTOSTART` unset or `""` ⇒ `:none` (FR-029 idle boot). A value that
is neither `ad-hoc` nor a breakdown package slug fails the boot loudly.

**Validation rules** (all fail the boot, never fall back silently — FR-020,
Constitution II):

- A required var that is absent ⇒ boot raises naming the variable.
- A numeric var that does not parse ⇒ raise naming the variable and the value.
- A `SPECKIT_MODEL_<PHASE>` value outside `Config.valid_models/0` ⇒ raise, listing
  the accepted aliases. Reuses the existing
  `Config.remediation_model/2` rejection shape.
- `<PHASE>` outside the known phase set ⇒ raise, listing known phases (mirrors
  `Config.model_for/1`).

---

## 5. `SpeckitOrchestrator.Container.Mount` (internal)

A parsed line of `/proc/self/mountinfo`, used only to answer "is this path a
mount point?" for `:run_state_durable` (FR-023, R10).

| Field | Type |
|---|---|
| `mount_point` | `String.t()` |
| `fs_type` | `String.t()` |
| `options` | `[String.t()]` |

**Pure function**: `Mount.mount_point?(mountinfo_lines, path) :: boolean()` —
parsing and matching take the file *contents*, so the hermetic suite tests
against fixture mountinfo text (including a tmpfs `$HOME` with a nested bind at
`$HOME/.autonomous`) with no container.

---

## Relationships

```
Container.Env ──validated at boot──▶ Application env (Config reads it)
      │
      └──▶ Boot ──▶ Preflight.collect ──▶ facts ──▶ Preflight.evaluate ──▶ Report
                          │                                                  │
                    ImageInfo.read                                     persisted JSON
                          │                                                  │
                    Container.Mount ────────────────────────────────▶ :run_state_durable
                                                                             │
                                              Report.status == :fail ──▶ stay idle (FR-031)
                                              Report.status != :fail ──▶ SpeckitOrchestrator.run/1
```

## What this feature does **not** change

- `Feature`, `Pipeline`, `Ledger`, `Release`, `Backlog`, `Layout` — untouched.
  Container isolation is a deployment concern; the pure core stays as-is, which
  is what makes SC-001 (run parity) achievable by construction.
- `Coordinator` and `Ledger` gain only `terminate/2` flush behaviour (FR-027) —
  no change to wave, DAG, or breaker semantics.
