defmodule Autonomous.Attachments.Limits do
  @moduledoc """
  Pure limit checks for attachments (feature 047). Maxima default to the
  `Config` accessors and are passed explicitly in tests.
  """

  alias Autonomous.Config

  @type reason ::
          {:too_many_files, pos_integer()}
          | {:too_large, non_neg_integer(), pos_integer()}
          | {:total_too_large, non_neg_integer(), pos_integer()}

  @doc "Is `count` files within the per-run file cap?"
  @spec check_count(non_neg_integer(), pos_integer()) :: :ok | {:error, reason()}
  def check_count(count, max \\ Config.attachment_max_files()) do
    if count <= max, do: :ok, else: {:error, {:too_many_files, max}}
  end

  @doc "Is a file of `size` bytes within the per-file cap?"
  @spec check_file(non_neg_integer(), pos_integer()) :: :ok | {:error, reason()}
  def check_file(size, max \\ Config.attachment_max_file_bytes()) do
    if size <= max, do: :ok, else: {:error, {:too_large, size, max}}
  end

  @doc "Is a combined `total` bytes within the per-run cap?"
  @spec check_total(non_neg_integer(), pos_integer()) :: :ok | {:error, reason()}
  def check_total(total, max \\ Config.attachment_max_total_bytes()) do
    if total <= max, do: :ok, else: {:error, {:total_too_large, total, max}}
  end
end
