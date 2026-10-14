defmodule Autonomous.ConversationFile do
  @moduledoc """
  IO boundary for the `speckit.conversation` v1 file (feature 040,
  `contracts/conversation-file.md`).

  Layout: `<transcript_root>/conversations/<run_id>/<feature_id>/<id>.jsonl`;
  directories `0700`, file `0600` (set before the first byte). Writes are
  appends of one JSON line per entry; reads stream and never load the whole
  file. A malformed line is reported with its (1-based file) line number and the
  entries before it are still returned — nothing is invented (Principle II).
  """

  alias Autonomous.{ConversationEntry, ConversationIdentity}

  @format "speckit.conversation"
  @version 2

  @type handle :: %{io: File.io_device(), path: Path.t(), rel: String.t()}

  @doc "Path of the file relative to the transcript root."
  @spec relative_path(ConversationIdentity.t(), String.t()) :: String.t()
  def relative_path(%ConversationIdentity{} = id, conversation_id),
    do: Path.join(["conversations", id.run_id, id.feature_id, conversation_id <> ".jsonl"])

  @doc "Absolute path of a stored relative path."
  @spec resolve(Path.t(), String.t()) :: Path.t()
  def resolve(transcript_root, rel), do: Path.join(transcript_root, rel)

  @doc """
  Create directories (`0700`) and the file (`0600`, exclusive), write the header.
  `{:error, {:open_failed, posix}}` on any failure; a name collision is `:eexist`.
  Returns the handle and the header's byte size.
  """
  @spec open(ConversationIdentity.t(), String.t(), String.t()) ::
          {:ok, handle(), non_neg_integer()} | {:error, {:open_failed, term()}}
  def open(%ConversationIdentity{} = id, conversation_id, opened_at) do
    rel = relative_path(id, conversation_id)
    path = resolve(id.transcript_root, rel)
    header = header(id, conversation_id, opened_at)

    with :ok <- make_dirs(id),
         {:ok, io} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600),
         :ok <- :file.write(io, header) do
      {:ok, %{io: io, path: path, rel: rel}, byte_size(header)}
    else
      {:error, reason} -> {:error, {:open_failed, reason}}
    end
  end

  defp make_dirs(id) do
    dirs =
      Enum.scan(["conversations", id.run_id, id.feature_id], id.transcript_root, fn seg, acc ->
        Path.join(acc, seg)
      end)

    with :ok <- File.mkdir_p(List.last(dirs)) do
      Enum.reduce_while(dirs, :ok, fn dir, :ok ->
        case File.chmod(dir, 0o700) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp header(id, conversation_id, opened_at) do
    m = ConversationIdentity.to_map(id)

    line =
      Map.merge(
        %{
          "format" => @format,
          "version" => @version,
          "conversation_id" => conversation_id,
          "opened_at" => opened_at
        },
        Map.take(m, ~w(run_id feature_id phase ordinal kind chunk attempt))
      )

    Jason.encode!(line) <> "\n"
  end

  @doc "Append one entry; `{:ok, bytes_written}` or `{:error, posix}`."
  @spec append(handle(), ConversationEntry.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(%{io: io}, %ConversationEntry{} = entry) do
    line = entry |> ConversationEntry.encode() |> Jason.encode!() |> Kernel.<>("\n")

    case :file.write(io, line) do
      :ok -> {:ok, byte_size(line)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(handle()) :: :ok
  def close(%{io: io}) do
    _ = File.close(io)
    :ok
  end

  @type read_error ::
          :missing
          | {:unreadable, term()}
          | {:unsupported_version, term()}
          | {:malformed, pos_integer()}

  @doc """
  Entries `from_seq ..< from_seq + limit` and the next seq (`:eof` at the end).
  Malformed content yields `{:error, {:malformed, line_no}, entries_before_it}`.
  """
  @spec page(Path.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [ConversationEntry.t()], non_neg_integer() | :eof}
          | {:error, read_error()}
          | {:error, {:malformed, pos_integer()}, [ConversationEntry.t()]}
  def page(path, from_seq, limit) when from_seq >= 0 and limit > 0 do
    with :ok <- readable(path),
         {:ok, header_line} <- read_header(path),
         :ok <- check_header(header_line) do
      lines =
        path
        |> File.stream!(:line)
        |> Stream.drop(1 + from_seq)
        |> Enum.take(limit + 1)

      {window, more} = Enum.split(lines, limit)

      case decode_lines(window, from_seq) do
        {:ok, entries} -> {:ok, entries, if(more == [], do: :eof, else: from_seq + limit)}
        {:error, reason, entries} -> {:error, reason, entries}
      end
    end
  rescue
    e in File.Error -> {:error, {:unreadable, e.reason}}
  end

  @doc """
  Fold `fun` over the entries in order, streaming line by line (the file is
  never loaded whole). Option `:through_seq` stops after that seq without
  reading past it, so a line the recorder is writing concurrently is never
  seen. A malformed line before the stop is `{:error, {:malformed, line_no}}`.
  """
  @spec fold(Path.t(), acc, (ConversationEntry.t(), acc -> acc), keyword()) ::
          {:ok, acc} | {:error, read_error()}
        when acc: term()
  def fold(path, acc, fun, opts \\ []) when is_function(fun, 2) do
    through = Keyword.get(opts, :through_seq)

    with :ok <- readable(path),
         {:ok, header_line} <- read_header(path),
         :ok <- check_header(header_line) do
      path
      |> File.stream!(:line)
      |> Stream.drop(1)
      |> Stream.with_index()
      |> Enum.reduce_while({:ok, acc}, fn {line, seq}, {:ok, acc} ->
        fold_line(line, seq, through, fun, acc)
      end)
    end
  rescue
    e in File.Error -> {:error, {:unreadable, e.reason}}
  end

  defp fold_line(_line, seq, through, _fun, acc) when is_integer(through) and seq > through,
    do: {:halt, {:ok, acc}}

  defp fold_line(line, seq, _through, fun, acc) do
    case Jason.decode(line) do
      {:ok, %{"seq" => ^seq, "kind" => _} = m} ->
        {:cont, {:ok, fun.(ConversationEntry.decode(m), acc)}}

      _ ->
        {:halt, {:error, {:malformed, seq + 2}}}
    end
  end

  @doc "The entry with `seq`, read without loading the file."
  @spec entry(Path.t(), non_neg_integer()) :: {:ok, ConversationEntry.t()} | {:error, term()}
  def entry(path, seq) do
    case page(path, seq, 1) do
      {:ok, [e], _} -> {:ok, e}
      {:ok, [], _} -> {:error, :not_found}
      {:error, reason, _} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parsed header map (refuses a newer version by name)."
  @spec header_of(Path.t()) :: {:ok, map()} | {:error, read_error()}
  def header_of(path) do
    with :ok <- readable(path),
         {:ok, line} <- read_header(path),
         :ok <- check_header(line) do
      Jason.decode(line)
    end
  end

  defp readable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, {:unreadable, :not_regular}}
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp read_header(path) do
    case path |> File.stream!(:line) |> Enum.take(1) do
      [line] -> {:ok, String.trim_trailing(line, "\n")}
      [] -> {:error, {:malformed, 1}}
    end
  end

  defp check_header(line) do
    case Jason.decode(line) do
      {:ok, %{"format" => @format, "version" => v}} when is_integer(v) and v <= @version -> :ok
      {:ok, %{"format" => @format, "version" => v}} -> {:error, {:unsupported_version, v}}
      _ -> {:error, {:malformed, 1}}
    end
  end

  defp decode_lines(lines, from_seq) do
    lines
    |> Enum.with_index(from_seq)
    |> Enum.reduce_while({:ok, []}, fn {line, seq}, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, %{"seq" => ^seq, "kind" => _} = m} ->
          {:cont, {:ok, [ConversationEntry.decode(m) | acc]}}

        _ ->
          {:halt, {:error, {:malformed, seq + 2}, Enum.reverse(acc)}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
