defmodule Autonomous.Attachments do
  @moduledoc """
  Boundary for the files a single-spec run is started with (feature 047).

  * `load/2` — read and validate every supplied file; returns the manifest plus
    the validated bytes, or a refusal naming **every** bad file. Writes nothing
    anywhere (the bytes stay in memory until a worktree exists).
  * `commit/3` — write the bytes into the feature's spec directory and commit
    them on the feature branch (`git add -f`), before the seed.
  * `verify/2` — compare each committed file with its recorded `sha256`.

  Content detection is `Attachments.Sniff`, limits are `Attachments.Limits`,
  naming is `Attachment`. This module owns the file reads and the git writes.
  """

  alias Autonomous.{Attachment, Config, Feature, Prompts, Worktree}
  alias Autonomous.Attachments.{Limits, Sniff}

  @type input :: Path.t() | {Path.t(), String.t()}
  @type refusal :: %{file: String.t(), reason: term()}
  @type payload :: {String.t(), binary()}

  @doc """
  Validate `inputs` (`path | {path, display_name}`) and build the manifest.

  `opts` may override the limits (`:max_files`, `:max_file_bytes`,
  `:max_total_bytes`); they default to `Config`.
  """
  @spec load([input()], keyword()) ::
          {:ok, {[Attachment.t()], [payload()]}} | {:error, {:attachments, [refusal()]}}
  def load(inputs, opts \\ [])
  def load([], _opts), do: {:ok, {[], []}}

  def load(inputs, opts) when is_list(inputs) do
    max_files = Keyword.get_lazy(opts, :max_files, &Config.attachment_max_files/0)
    max_file = Keyword.get_lazy(opts, :max_file_bytes, &Config.attachment_max_file_bytes/0)
    max_total = Keyword.get_lazy(opts, :max_total_bytes, &Config.attachment_max_total_bytes/0)

    results =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {input, index} ->
        {path, name} = normalize(input)

        if index >= max_files do
          {:error, %{file: name, reason: elem(Limits.check_count(index + 1, max_files), 1)}}
        else
          read_one(path, name, max_file)
        end
      end)

    case refusals(results, max_total) do
      [] -> build(results)
      list -> {:error, {:attachments, list}}
    end
  end

  defp normalize({path, name}) when is_binary(path) and is_binary(name), do: {path, name}
  defp normalize(path) when is_binary(path), do: {path, Path.basename(path)}

  defp read_one(path, name, max_file) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- stat(path),
         :ok <- Limits.check_file(size, max_file),
         {:ok, bytes} <- read(path),
         {:ok, type} <- Sniff.detect(name, bytes) do
      {:ok, %{name: name, type: type, bytes: bytes}}
    else
      {:ok, %File.Stat{}} -> {:error, %{file: name, reason: :unreadable}}
      {:error, :enoent} -> {:error, %{file: name, reason: :not_found}}
      {:error, {:posix, _}} -> {:error, %{file: name, reason: :unreadable}}
      {:error, reason} -> {:error, %{file: name, reason: reason}}
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :enoent}
      {:error, posix} -> {:error, {:posix, posix}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, posix} -> {:error, {:posix, posix}}
    end
  end

  # Per-file refusals, plus the first file that pushes the running total over.
  defp refusals(results, max_total) do
    errors = for {:error, r} <- results, do: r

    {_, total_errors} =
      Enum.reduce(results, {0, []}, fn
        {:ok, %{name: name, bytes: bytes}}, {sum, acc} ->
          sum = sum + byte_size(bytes)

          case {Limits.check_total(sum, max_total), acc} do
            {{:error, reason}, []} -> {sum, [%{file: name, reason: reason}]}
            _ -> {sum, acc}
          end

        _error, state ->
          state
      end)

    errors ++ total_errors
  end

  defp build(results) do
    oks = for {:ok, r} <- results, do: r
    names = Attachment.stored_names(Enum.map(oks, &{&1.name, &1.type}))

    manifest =
      Enum.zip_with(oks, names, fn r, stored ->
        %Attachment{
          original_name: r.name,
          stored_name: stored,
          type: r.type,
          media_type: Attachment.media_type(r.type),
          size: byte_size(r.bytes),
          sha256: sha256(r.bytes)
        }
      end)

    payloads = Enum.zip_with(oks, names, fn r, stored -> {stored, r.bytes} end)
    {:ok, {manifest, payloads}}
  end

  @doc """
  The prompt section telling a session about the feature's attachments
  (contract `session-prompt-block`). `""` when there are none, so a text-only
  prompt is byte-identical. Only `stored_name`/`media_type`/size are rendered,
  never `original_name`.
  """
  @spec prompt_block(Feature.t(), atom()) :: String.t()
  def prompt_block(%Feature{attachments: []}, _phase), do: ""
  def prompt_block(%Feature{attachments: nil}, _phase), do: ""

  def prompt_block(%Feature{attachments: manifest} = feature, phase) do
    list =
      Enum.map_join(manifest, "\n", fn %Attachment{} = a ->
        "- #{Attachment.location(feature, a)} (#{a.media_type}, #{Attachment.format_size(a.size)})"
      end)

    common = String.replace(Prompts.load("attachments"), "{{LIST}}", list)

    extra =
      case phase do
        :specify -> "\n" <> Prompts.load("attachments_specify")
        :clarify -> "\n" <> Prompts.load("attachments_clarify")
        _ -> ""
      end

    ("\n\n" <> String.trim_trailing(common) <> "\n" <> String.trim_trailing(extra))
    |> String.trim_trailing()
  end

  @doc """
  PR-body section listing the files the feature was built from. Paths are plain
  code spans (a relative link does not resolve in a PR body); `stored_name` only.
  `""` when there are none.
  """
  @spec pr_note(Feature.t()) :: String.t()
  def pr_note(%Feature{attachments: manifest}) when manifest in [nil, []], do: ""

  def pr_note(%Feature{attachments: manifest} = feature) do
    items =
      Enum.map_join(manifest, "\n", fn %Attachment{} = a ->
        "- `#{Attachment.location(feature, a)}` (#{a.media_type}, #{Attachment.format_size(a.size)})"
      end)

    "\n\n## Attachments\n\nThis feature was built from these files:\n\n" <> items
  end

  @doc "Lowercase hex SHA-256 of `bytes`."
  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Write `payloads` into the feature's attachment directory inside `worktree`
  and commit them on the feature branch. An empty manifest is a no-op.
  """
  @spec commit(Feature.t(), Worktree.t(), [payload()]) :: :ok | {:error, term()}
  def commit(%Feature{attachments: []}, _worktree, _payloads), do: :ok
  def commit(%Feature{}, _worktree, []), do: :ok

  def commit(%Feature{attachments: manifest} = feature, %Worktree{} = worktree, payloads) do
    dir = Attachment.directory(feature)
    by_name = Map.new(payloads)

    with :ok <- File.mkdir_p(Path.join(worktree.path, dir)) |> wrap(:mkdir),
         :ok <- write_all(worktree, dir, manifest, by_name) do
      message = "speckit: #{feature.id} attachments (#{length(manifest)} files)"

      case Worktree.commit_paths(worktree, [dir], message) do
        :ok -> :ok
        :noop -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_all(worktree, dir, manifest, by_name) do
    Enum.reduce_while(manifest, :ok, fn %Attachment{stored_name: name}, :ok ->
      with {:ok, bytes} <- Map.fetch(by_name, name) |> missing(name),
           :ok <- File.write(Path.join([worktree.path, dir, name]), bytes) |> wrap(name) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp missing({:ok, _} = ok, _name), do: ok
  defp missing(:error, name), do: {:error, {:missing_payload, name}}

  defp wrap(:ok, _), do: :ok
  defp wrap({:error, posix}, what), do: {:error, {:write_failed, what, posix}}

  @doc """
  Re-read every committed attachment and compare its `sha256`. A changed or
  missing file is reported by stored name.
  """
  @spec verify(Feature.t(), Worktree.t()) :: :ok | {:error, {:attachments_changed, [String.t()]}}
  def verify(%Feature{attachments: []}, _worktree), do: :ok

  def verify(%Feature{attachments: manifest} = feature, %Worktree{path: root}) do
    changed =
      for %Attachment{stored_name: name, sha256: expected} = a <- manifest,
          not intact?(Path.join(root, Attachment.location(feature, a)), expected),
          do: name

    if changed == [], do: :ok, else: {:error, {:attachments_changed, changed}}
  end

  defp intact?(path, expected) do
    case File.read(path) do
      {:ok, bytes} -> sha256(bytes) == expected
      {:error, _} -> false
    end
  end
end
