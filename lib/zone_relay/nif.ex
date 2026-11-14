defmodule ZoneRelay.Nif do
  @moduledoc """
  One zone of the relay as a resource. The body of every function runs in Mojo
  (`native/zone_relay.mojo`). Use a zone from one process at a time.
  """
  @on_load :load_nif

  def load_nif do
    :zone_relay
    |> Application.app_dir("priv/native/libzone_nif")
    |> String.to_charlist()
    |> :erlang.load_nif(0)
  end

  @doc "A new zone, reset."
  def new, do: :erlang.nif_error(:nif_not_loaded)
  def reset(_zone), do: :erlang.nif_error(:nif_not_loaded)
  @doc "Slot held by `person`, or -1 when all four are taken."
  def join(_zone, _person), do: :erlang.nif_error(:nif_not_loaded)
  @doc "1 when a slot was freed, else 0."
  def leave(_zone, _person), do: :erlang.nif_error(:nif_not_loaded)
  @doc "Person in `slot`, -1 when empty."
  def person_at(_zone, _slot), do: :erlang.nif_error(:nif_not_loaded)
  @doc "1 when the frame was taken, 0 when refused."
  def put(_zone, _slot, _half, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  @doc "Frame `k` (0..5) a `viewer` is handed, as a binary (copy)."
  def frame(_zone, _viewer, _k), do: :erlang.nif_error(:nif_not_loaded)
  @doc "One tick; returns `now`."
  def tick(_zone), do: :erlang.nif_error(:nif_not_loaded)
  @doc "Frames refused because their half was taken too recently."
  def unread(_zone), do: :erlang.nif_error(:nif_not_loaded)
end
