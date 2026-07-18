defmodule SpeckitOrchestrator.Describe do
  @moduledoc """
  Optional post-pipeline step: ask Claude to author the **commit message** and the
  **pull-request title/body** for a finished feature, from its spec and real diff
  (see `priv/prompts/describe.md`). The orchestrator then executes the commit /
  push / PR with that text — Claude authors, the orchestrator runs `git`/`gh`.

  Best-effort: any failure returns `{:error, _}` and the caller falls back to its
  mechanical templates, so a describe hiccup never blocks a commit or PR.
  """

  alias SpeckitOrchestrator.{Config, PhaseRequest, PhaseResult}

  @type description :: %{commit_message: String.t(), pr_title: String.t(), pr_body: String.t()}

  @doc """
  Run the describe step in `worktree` (which must still hold the feature's files
  and git history). Returns `{:ok, description}` or `{:error, reason}`.
  """
  @spec run(SpeckitOrchestrator.Feature.t(), map()) :: {:ok, description()} | {:error, term()}
  def run(feature, %{path: path}) do
    request = PhaseRequest.build(feature, :describe, cwd: path)

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} -> parse(PhaseResult.reduce(stream).final_text)
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_feature, _no_worktree), do: {:error, :no_worktree}

  @doc """
  Recover the description JSON from a transcript. Prefers the last fenced ```json
  block, else the last balanced `{...}`; accepted only if it decodes and carries
  a `pr_body`. Missing `commit_message`/`pr_title` default to empty strings.
  """
  @spec parse(String.t() | nil) :: {:ok, description()} | {:error, term()}
  def parse(text) when is_binary(text) do
    text
    |> candidates()
    |> Enum.reverse()
    |> Enum.find_value({:error, :no_description_json}, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{"pr_body" => body} = obj} when is_binary(body) ->
          {:ok,
           %{
             commit_message: string(obj, "commit_message"),
             pr_title: string(obj, "pr_title"),
             pr_body: body
           }}

        _ ->
          false
      end
    end)
  end

  def parse(_), do: {:error, :no_description_json}

  # ---- PR text handoff ----------------------------------------------------
  #
  # The describe step runs in the data plane (FeatureRunner, while the worktree
  # still exists); the facade opens the PR later (after teardown). The PR title/
  # body travel between them via a small file under the durable transcript dir.

  @doc "Persist the PR title/body for `feature_id` under the transcript dir."
  @spec write_pr(String.t(), %{pr_title: String.t(), pr_body: String.t()}) :: :ok
  def write_pr(feature_id, %{pr_title: title, pr_body: body}) do
    dir = Path.join(Config.transcript_root(), feature_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "pr.json"), Jason.encode!(%{pr_title: title, pr_body: body}))
    :ok
  end

  @doc "Read a previously-written PR title/body, or `:error` if absent/malformed."
  @spec read_pr(String.t()) :: {:ok, %{pr_title: String.t(), pr_body: String.t()}} | :error
  def read_pr(feature_id) do
    path = Path.join([Config.transcript_root(), feature_id, "pr.json"])

    with {:ok, raw} <- File.read(path),
         {:ok, %{"pr_title" => t, "pr_body" => b}} when is_binary(t) and is_binary(b) <-
           Jason.decode(raw) do
      {:ok, %{pr_title: t, pr_body: b}}
    else
      _ -> :error
    end
  end

  # ---- JSON recovery ------------------------------------------------------

  @fence_re ~r/```(?:json)?\s*(\{.*?\})\s*```/s

  defp candidates(text) do
    fenced =
      @fence_re
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(&hd/1)

    fenced ++ brace_objects(text)
  end

  # Balanced top-level `{...}` substrings, in order (naive brace counting — the
  # describe JSON is our own controlled, fenced output).
  defp brace_objects(text), do: do_scan(String.to_charlist(text), 0, [], [])

  defp do_scan([], _depth, _cur, acc), do: Enum.reverse(acc)
  defp do_scan([?{ | rest], 0, _cur, acc), do: do_scan(rest, 1, [?{], acc)
  defp do_scan([?{ | rest], depth, cur, acc), do: do_scan(rest, depth + 1, [?{ | cur], acc)

  defp do_scan([?} | rest], 1, cur, acc) do
    obj = [?} | cur] |> Enum.reverse() |> List.to_string()
    do_scan(rest, 0, [], [obj | acc])
  end

  defp do_scan([?} | rest], depth, cur, acc) when depth > 1,
    do: do_scan(rest, depth - 1, [?} | cur], acc)

  defp do_scan([_c | rest], 0, cur, acc), do: do_scan(rest, 0, cur, acc)
  defp do_scan([c | rest], depth, cur, acc), do: do_scan(rest, depth, [c | cur], acc)

  defp string(obj, key) do
    case Map.get(obj, key) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end
end
