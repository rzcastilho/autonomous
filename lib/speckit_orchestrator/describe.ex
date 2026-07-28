defmodule SpeckitOrchestrator.Describe do
  @moduledoc """
  Optional post-pipeline step: ask Claude to author the **commit message** and the
  **pull-request title/body** for a finished feature, from its spec and real diff
  (see `priv/prompts/describe.md`). The orchestrator then executes the commit /
  push / PR with that text — Claude authors, the orchestrator runs `git`/`gh`.

  Best-effort: any failure returns `{:error, _}` and the caller falls back to its
  mechanical templates, so a describe hiccup never blocks a commit or PR.
  """

  alias SpeckitOrchestrator.{Layout, PhaseRequest, PhaseResult}

  @type description :: %{commit_message: String.t(), pr_title: String.t(), pr_body: String.t()}

  @doc """
  Run the describe step in `worktree` (which must still hold the feature's files
  and git history). `layout` (optional) threads the run's `%Layout{}` into the
  breakdown-ref prompt (T014); `nil` falls back to `Config.breakdown_dir/0`.
  Returns `{:ok, description}` or `{:error, reason}`.
  """
  @spec run(SpeckitOrchestrator.Feature.t(), map(), Layout.t() | nil) ::
          {:ok, description()} | {:error, term()}
  def run(feature, worktree, layout \\ nil)

  def run(feature, %{path: path}, layout) do
    request = PhaseRequest.build(feature, :describe, cwd: path, layout: layout)

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} -> parse(PhaseResult.reduce(stream).final_text)
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_feature, _no_worktree, _layout), do: {:error, :no_worktree}

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
