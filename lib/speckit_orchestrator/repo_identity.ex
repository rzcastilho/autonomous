defmodule SpeckitOrchestrator.RepoIdentity do
  @moduledoc """
  Pure derivation of a repository-identity segment (`<repo-name>-<shorthash>`)
  from a repository's `origin` remote, plus the one IO boundary that reads it.

  `canonicalize/1` and `segment/1` are pure and hermetic (`:crypto.hash/2` is
  deterministic — not one of the banned nondeterministic calls). Only
  `resolve/1` touches git, mirroring `TargetPack.check_remote/3`'s origin read.
  See `specs/012-run-directory-layout/contracts/repo-identity.md`.
  """

  @doc """
  Reduce an origin URL to `host/owner/repo`: strip scheme, `git@`/`user@` SSH
  prefix, normalize SCP-style `host:owner/repo` to `host/owner/repo`, strip a
  trailing `.git` and trailing `/`, lower-case the host only.
  """
  @spec canonicalize(String.t()) :: {:ok, String.t()} | :error
  def canonicalize(url) when is_binary(url) do
    with stripped <- strip_scheme(url),
         stripped <- strip_user(stripped),
         stripped <- scp_to_slash(stripped),
         stripped <- String.trim_trailing(stripped, "/"),
         stripped <- strip_dot_git(stripped),
         [host | rest] when rest != [] <- String.split(stripped, "/", parts: 2) do
      {:ok, Enum.join([String.downcase(host) | rest], "/")}
    else
      _ -> :error
    end
  end

  @doc """
  `"\#{name}-\#{shorthash}"` where `name` is the last path segment of `canonical`
  (the repo) and `shorthash` is the first 6 hex chars of
  `:crypto.hash(:sha256, canonical)`.
  """
  @spec segment(String.t()) :: String.t()
  def segment(canonical) when is_binary(canonical) do
    name = canonical |> String.split("/") |> List.last()

    shorthash =
      :crypto.hash(:sha256, canonical)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 6)

    "#{name}-#{shorthash}"
  end

  @doc """
  Read `repo`'s `origin` remote (`git -C <repo> remote get-url origin`) and
  resolve it to a `segment/1`. `{:error, :no_origin}` on a missing remote or a
  URL that fails to `canonicalize/1` — an unusable origin is treated as no
  usable origin (FR-002).
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :no_origin}
  def resolve(repo) when is_binary(repo) do
    case System.cmd("git", ["-C", repo, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> canonicalize() do
          {:ok, canonical} -> {:ok, segment(canonical)}
          :error -> {:error, :no_origin}
        end

      {_, _} ->
        {:error, :no_origin}
    end
  end

  # ---- normalization helpers ----------------------------------------------

  defp strip_scheme(url), do: Regex.replace(~r{^[a-zA-Z]+://}, url, "")

  # `git@host:...` / `user@host/...` — drop the user@ prefix, whichever form
  # follows (scp-style colon or already scheme-stripped slash form).
  defp strip_user(url), do: Regex.replace(~r{^[^/@\s]+@}, url, "")

  # `host:owner/repo` (no scheme, no slash before the colon) -> `host/owner/repo`.
  defp scp_to_slash(url) do
    case Regex.run(~r{^([^/:\s]+):(.+)$}, url) do
      [_, host, rest] -> host <> "/" <> rest
      nil -> url
    end
  end

  defp strip_dot_git(url), do: Regex.replace(~r{\.git$}, url, "")
end
