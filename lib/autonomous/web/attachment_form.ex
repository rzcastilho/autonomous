defmodule Autonomous.Web.AttachmentForm do
  @moduledoc """
  Pure triage of the Trigger form's upload entries (feature 047).

  The LiveView hands in each entry's client-declared name and size plus the
  errors LiveView itself raised; this module decides which entries stay and
  which are cancelled, and why — as `Attachments`-shaped refusals
  (`%{file:, reason:}`) so `Report.format_reason/1` renders them the same way a
  `run_spec/2` refusal reads. No LiveView, no IO. Entries are judged in the
  order given, and the verdict is idempotent: re-triaging the surviving
  entries changes nothing.
  """

  @type entry :: %{
          ref: String.t(),
          name: String.t(),
          size: non_neg_integer(),
          errors: [atom()]
        }

  @type limits :: %{
          max_files: pos_integer(),
          max_file_bytes: pos_integer(),
          max_total_bytes: pos_integer()
        }

  @type result :: %{
          keep: [String.t()],
          cancel: [String.t()],
          refusals: [%{file: String.t(), reason: term()}]
        }

  @doc "Which entries to keep and which to cancel, with a named refusal per cancelled one."
  @spec triage([entry()], limits()) :: result()
  def triage(entries, limits) do
    {keep, cancel, refusals, _count, _total} =
      Enum.reduce(entries, {[], [], [], 0, 0}, fn entry, {keep, cancel, refusals, count, total} ->
        case verdict(entry, count, total, limits) do
          :keep ->
            {[entry.ref | keep], cancel, refusals, count + 1, total + entry.size}

          {:refuse, reason} ->
            {keep, [entry.ref | cancel], [%{file: entry.name, reason: reason} | refusals], count,
             total}
        end
      end)

    %{keep: Enum.reverse(keep), cancel: Enum.reverse(cancel), refusals: Enum.reverse(refusals)}
  end

  defp verdict(%{errors: [error | _]} = entry, _count, _total, limits),
    do: {:refuse, error_reason(error, entry, limits)}

  defp verdict(%{size: 0}, _count, _total, _limits), do: {:refuse, :empty}

  defp verdict(_entry, count, _total, %{max_files: max}) when count >= max,
    do: {:refuse, {:too_many_files, max}}

  defp verdict(%{size: size}, _count, total, %{max_total_bytes: max}) when total + size > max,
    do: {:refuse, {:total_too_large, total + size, max}}

  defp verdict(_entry, _count, _total, _limits), do: :keep

  defp error_reason(:too_large, %{size: size}, %{max_file_bytes: max}),
    do: {:too_large, size, max}

  defp error_reason(:too_many_files, _entry, %{max_files: max}), do: {:too_many_files, max}
  defp error_reason(:not_accepted, _entry, _limits), do: :unsupported_type
  defp error_reason(_other, _entry, _limits), do: :unreadable
end
