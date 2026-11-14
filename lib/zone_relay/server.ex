defmodule ZoneRelay.Server do
  @moduledoc """
  Elixir runs the server: two UDP sockets (first frames on `port`, second frames
  on `port + 1`, so the half of a datagram is the socket it came on) and a 64 Hz
  tick. Mojo runs the relay: every put, frame and tick goes through `ZoneRelay.Nif`.
  Mirrors `src/zone_net.c`.
  """
  use GenServer
  import Bitwise

  @tick_us 15_625
  @slots 4
  @max_zones 1024
  @max_people @max_zones * @slots
  @frame_max 1472

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @doc "Counters since start."
  def report(server), do: GenServer.call(server, :report)
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    host = Keyword.get(opts, :host, {127, 0, 0, 1})
    port = Keyword.fetch!(opts, :port)
    sock_opts = [:binary, active: true, ip: host, recbuf: 1 <<< 22, sndbuf: 1 <<< 22]
    {:ok, s0} = :gen_udp.open(port, sock_opts)
    {:ok, s1} = :gen_udp.open(port + 1, sock_opts)
    start = System.monotonic_time(:microsecond)

    state = %{
      socks: {s0, s1},
      start: start,
      counted: 0,
      people: %{},
      addrs: %{},
      zones: %{},
      slot_of: %{},
      seated: %{},
      stats: %{ticks: 0, overruns: 0, frames_in: 0, datagrams_out: 0, refused: 0, strangers: 0, send_failed: 0}
    }

    schedule(state, 1)
    {:ok, state}
  end

  defp schedule(%{start: start}, n) do
    at_us = start + n * @tick_us
    delay_ms = max(div(at_us - System.monotonic_time(:microsecond), 1000), 0)
    Process.send_after(self(), :tick, delay_ms)
  end

  @impl true
  def handle_info(:tick, state) do
    elapsed = System.monotonic_time(:microsecond) - state.start
    wall = max(div(elapsed, @tick_us), state.counted + 1)
    owed = wall - state.counted
    for _ <- 1..owed//1, {_i, z} <- state.zones, do: ZoneRelay.Nif.tick(z)
    overruns = if owed > 1, do: 1, else: 0
    stats = %{state.stats | ticks: wall, overruns: state.stats.overruns + overruns}
    state = %{state | counted: wall, stats: stats}
    schedule(state, wall + 1)
    {:noreply, state}
  end

  def handle_info({:udp, sock, ip, port, data}, state) do
    half = if sock == elem(state.socks, 0), do: 0, else: 1
    {:noreply, datagram(state, half, {ip, port}, data)}
  end

  @impl true
  def handle_call(:report, _from, state) do
    unread = state.zones |> Map.values() |> Enum.map(&ZoneRelay.Nif.unread/1) |> Enum.sum()
    {:reply, Map.merge(state.stats, %{people: map_size(state.people), unread: unread}), state}
  end

  # Mirrors the body of the receive loop of zn_run.
  defp datagram(state, _half, _from, data) when byte_size(data) > @frame_max,
    do: bump(state, :refused)

  defp datagram(state, half, from, data) do
    case person_of(state, from) do
      {:error, state} ->
        bump(state, :strangers)

      {p, state} ->
        zi = div(p, @slots)
        {z, state} = zone(state, zi)

        case seat(state, z, zi, p) do
          {:error, state} ->
            bump(state, :refused)

          {slot, state} ->
            if ZoneRelay.Nif.put(z, slot, half, data) == 1 do
              state |> bump(:frames_in) |> fan_out(z, zi, slot, half)
            else
              bump(state, :refused)
            end
        end
    end
  end

  defp fan_out(state, z, zi, slot, half) do
    sock = elem(state.socks, half)

    Enum.reduce(0..(@slots - 1), state, fn v, st ->
      if v == slot or ZoneRelay.Nif.person_at(z, v) < 0 do
        st
      else
        held = ZoneRelay.Nif.frame(z, v, (if slot > v, do: slot - 1, else: slot) * 2 + half)
        {ip, port} = Map.fetch!(st.addrs, Map.fetch!(st.seated, {zi, v}))

        case :gen_udp.send(sock, ip, port, held) do
          :ok -> bump(st, :datagrams_out)
          _ -> bump(st, :send_failed)
        end
      end
    end)
  end

  defp person_of(state, from) do
    case state.people do
      %{^from => p} ->
        {p, state}

      people when map_size(people) >= @max_people ->
        {:error, state}

      people ->
        p = map_size(people)
        {p, %{state | people: Map.put(people, from, p), addrs: Map.put(state.addrs, p, from)}}
    end
  end

  defp zone(state, zi) do
    case state.zones do
      %{^zi => z} -> {z, state}
      zones -> z = ZoneRelay.Nif.new(); {z, %{state | zones: Map.put(zones, zi, z)}}
    end
  end

  defp seat(state, z, zi, p) do
    slot = Map.get(state.slot_of, p, -1)

    if slot >= 0 and ZoneRelay.Nif.person_at(z, slot) == p do
      {slot, state}
    else
      case ZoneRelay.Nif.join(z, p) do
        -1 -> {:error, state}
        s -> {s, %{state | slot_of: Map.put(state.slot_of, p, s), seated: Map.put(state.seated, {zi, s}, p)}}
      end
    end
  end

  defp bump(state, key), do: %{state | stats: Map.update!(state.stats, key, &(&1 + 1))}
end
