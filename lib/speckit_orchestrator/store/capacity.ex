defmodule SpeckitOrchestrator.Store.Capacity do
  @moduledoc """
  Pure capacity policy (018, contracts/capacity-and-prune.md § Capacity). No
  IO, no `:mnesia` reference — measurement is the caller's job
  (`Store.Query.capacity/0`); this module only decides.
  """

  @type measurement :: %{
          used_bytes: non_neg_integer(),
          capacity_bytes: pos_integer(),
          headroom_bytes: non_neg_integer(),
          reclaimable_bytes: non_neg_integer()
        }

  @type refusal :: %{
          shortfall_bytes: pos_integer(),
          used_bytes: non_neg_integer(),
          capacity_bytes: pos_integer(),
          headroom_bytes: non_neg_integer(),
          reclaimable_bytes: non_neg_integer()
        }

  @doc """
  `:ok` when `used + headroom <= capacity`; otherwise `{:refuse, refusal}`
  naming the shortfall (contracts/capacity-and-prune.md § Capacity — pure
  policy). `reclaimable_bytes` passes through unchanged for the refusal
  message (FR-031b).
  """
  @spec check(measurement()) :: :ok | {:refuse, refusal()}
  def check(%{used_bytes: used, capacity_bytes: capacity, headroom_bytes: headroom} = m)
      when is_integer(used) and used >= 0 and is_integer(capacity) and capacity > 0 and
             is_integer(headroom) and headroom >= 0 do
    if used + headroom <= capacity do
      :ok
    else
      {:refuse,
       %{
         shortfall_bytes: used + headroom - capacity,
         used_bytes: used,
         capacity_bytes: capacity,
         headroom_bytes: headroom,
         reclaimable_bytes: Map.get(m, :reclaimable_bytes, 0)
       }}
    end
  end
end
