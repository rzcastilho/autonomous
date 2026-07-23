# Contract: RepoIdentity

Pure derivation of a repository-identity segment, plus one IO boundary function
that reads the `origin` remote. Isolates the git dependency from the pure
canonicalize/hash logic (Constitution I).

## `canonicalize/1` (pure)

```elixir
@spec canonicalize(String.t()) :: {:ok, String.t()} | :error
```

Reduce an origin URL to `host/owner/repo`. Returns `:error` for input with no
recognizable host/path.

Normalizations (applied before returning):
- strip scheme (`https://`, `http://`, `ssh://`, `git://`)
- strip `git@` (or any `user@`) SSH prefix
- convert `host:owner/repo` (SCP-style) → `host/owner/repo`
- strip a single trailing `.git`
- strip a trailing `/`
- lower-case the host only (path case preserved)

Equivalence (MUST hold):

| Input | `canonical` |
|-------|-------------|
| `git@github.com:rzcastilho/ledgerlite.git` | `github.com/rzcastilho/ledgerlite` |
| `https://github.com/rzcastilho/ledgerlite.git` | `github.com/rzcastilho/ledgerlite` |
| `https://github.com/rzcastilho/ledgerlite/` | `github.com/rzcastilho/ledgerlite` |
| `ssh://git@github.com/rzcastilho/ledgerlite` | `github.com/rzcastilho/ledgerlite` |

Different owner or host MUST NOT canonicalize to the same string.

## `segment/1` (pure)

```elixir
@spec segment(String.t()) :: String.t()   # input: canonical form
```

Returns `"#{name}-#{shorthash}"`:
- `name` = last path segment of `canonical` (the `repo`)
- `shorthash` = `:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower) |> binary_part(0, 6)`

Properties (MUST hold):
- Deterministic: same `canonical` → same `segment`.
- `github.com/rzcastilho/ledgerlite` → `ledgerlite-<6hex>`.
- Same repo name under different owner/host → same `name`, different `shorthash`.

## `resolve/1` (IO boundary)

```elixir
@spec resolve(repo :: String.t()) :: {:ok, String.t()} | {:error, :no_origin}
```

- Runs `git -C <repo> remote get-url origin` (mirrors `TargetPack.check_remote/3`).
- Non-zero exit (no `origin`) → `{:error, :no_origin}` (FR-002).
- Zero exit → `canonicalize/1` the URL, then `segment/1`; a URL that fails to
  canonicalize is also `{:error, :no_origin}` (an unusable origin is treated as
  no usable origin, per spec edge case).

The facade calls `resolve/1` at preflight; `{:error, :no_origin}` refuses the
run with a message naming the missing `origin` remote (SC-004). Only `origin`
participates — other remotes are ignored (spec edge case).
