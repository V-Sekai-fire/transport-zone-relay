# Four clients, the relay as a process, and the load generator; see docs/clients.md.
#   GODOT=<double editor> MUJOCO_ELF=<file> CLIPS=<dir> [SECONDS=20] [LOAD=<people>] elixir tools/clients.exs [--control=half|drift]
defmodule Clients do
  @port 47600
  @row 64

  def main(args) do
    [godot, elf, clips] = for k <- ~w(GODOT MUJOCO_ELF CLIPS), do: System.get_env(k) || fail("set #{k}")
    seconds = String.to_integer(System.get_env("SECONDS") || "20")
    load = String.to_integer(System.get_env("LOAD") || "0")
    control = Enum.find_value(args, "", fn a -> if String.starts_with?(a, "--control="), do: String.replace_prefix(a, "--control=", "") end)
    relay = System.get_env("RELAY") || System.get_env("RELAY_HOST") && "." || Enum.find(["../transport-zone-relay", "../../1-transport/zone-relay"], &File.dir?/1) || fail("set RELAY")
    out = Path.join(System.tmp_dir!(), "clients-#{System.os_time(:millisecond)}")
    File.mkdir_p!(out)
    cc = System.get_env("CC") || "cc"
    plant = if control == "half", do: ["-DZN_PLANT_HALF"], else: []
    src = Path.join(relay, "src")
    unless System.get_env("RELAY_HOST"), do: {_, 0} = System.cmd(cc, ["-std=c99", "-O2"] ++ plant ++ ["-o", Path.join(out, "zone_serve")] ++ Enum.map(~w(zone_serve.c zone_net.c zone_relay.c), &Path.join(src, &1)))
    unless System.get_env("RELAY_HOST"), do: {_, 0} = System.cmd(cc, ["-std=c99", "-O2", "-o", Path.join(out, "zone_load"), Path.join(src, "zone_load.c")])

    ticks = (seconds + 8) * 64
    remote = System.get_env("RELAY_HOST")
    relays = if remote, do: 0, else: String.to_integer(System.get_env("RELAYS") || "1")
    serves = for i <- 0..(relays - 1)//1, do: Task.async(fn -> System.cmd(Path.join(out, "zone_serve"), ["#{@port + 10 * i}", "#{ticks}", "0"], stderr_to_stdout: true) end)
    Process.sleep(300)
    epoch = System.os_time(:microsecond) + 4_000_000

    clients =
      for slot <- 0..3 do
        skew = if control == "drift" and slot == 3, do: ["--skew-ppm=20000"], else: []
        Task.async(fn ->
          System.cmd(godot, ["--headless", "--path", ".", "-s", "tests/client.gd", "--", "#{slot}", "#{@port}", "#{epoch}", "#{seconds}", elf, clips, out] ++ skew, stderr_to_stdout: true)
        end)
      end

    loaders =
      if load > 0 do
        Process.sleep(6_000)
        for i <- 0..(relays - 1)//1, share = div(load, relays) + if(i < rem(load, relays), do: 1, else: 0), share > 0 do
          Task.async(fn -> System.cmd(Path.join(out, "zone_load"), ["#{@port + 10 * i}", "#{share}", "#{(seconds - 3) * 64}"], stderr_to_stdout: true) end)
        end
      else
        []
      end

    lines = for c <- clients, {o, _} = Task.await(c, :infinity), l <- String.split(o, "\n"), String.starts_with?(l, "CLIENT") or String.starts_with?(l, "RESULT: ERROR"), do: l
    Enum.each(lines, &IO.puts/1)
    zint = fn line, key -> case Regex.run(~r/ #{key}=(\d+)/, line) do [_, n] -> String.to_integer(n); _ -> 0 end end
    slow = for l <- loaders, {o, _} = Task.await(l, :infinity), do: zint.(o, "slow_passes")
    zones = for sv <- serves, {so, _} = Task.await(sv, :infinity), do: so |> String.split("\n") |> hd()
    for {z, i} <- Enum.with_index(zones), do: IO.puts("RELAY #{i} people=#{zint.(z, "people")} frames_in=#{zint.(z, "frames_in")} datagrams_out=#{zint.(z, "datagrams_out")} refused=#{zint.(z, "refused")} overruns=#{zint.(z, "overruns")} of #{zint.(z, "ticks")}")
    people = zones |> Enum.map(&zint.(&1, "people")) |> Enum.sum()
    worst_over = zones |> Enum.map(&zint.(&1, "overruns")) |> Enum.max(fn -> 0 end)
    relay_refused = zones |> Enum.map(&zint.(&1, "refused")) |> Enum.sum()

    sent = for s <- 0..3, into: %{}, do: {s, rows(Path.join(out, "sent.#{s}.f64"))}
    pairs =
      for v <- 0..3, s <- 0..3, v != s do
        seen = rows(Path.join(out, "seen.#{v}.#{s}.f64"))
        ds = for {t, parts} <- seen, was = sent[s][t], was != nil, {a, b} <- Enum.zip(Enum.chunk_every(parts, 3), Enum.chunk_every(was, 3)), do: dist(a, b)
        {v, s, length(ds), if(ds == [], do: nil, else: Enum.sum(ds) / length(ds)), if(ds == [], do: nil, else: Enum.max(ds))}
      end

    seeing = Enum.count(pairs, fn {_, _, n, mean, _} -> n > 0 and mean < 5.0 end)
    blind = for {v, s, n, mean, _} <- pairs, n == 0 or mean >= 5.0, do: "#{v} of #{s}"
    means = for {_, _, n, mean, _} <- pairs, n > 0, do: mean
    maxes = for {_, _, n, _, max} <- pairs, n > 0, do: max
    num = fn list, f -> if list == [], do: "none", else: :erlang.float_to_binary(f.(list), decimals: 3) end
    counts = fn key -> lines |> Enum.map(&Regex.run(~r/ #{key}=(\d+)/, &1)) |> Enum.reject(&is_nil/1) |> Enum.map(&String.to_integer(Enum.at(&1, 1))) |> Enum.sum() end
    IO.puts("LEDGER pairs_seeing=#{seeing} err_mean_mm=#{num.(means, &(Enum.sum(&1) / length(&1)))} err_max_mm=#{num.(maxes, &Enum.max/1)} judged=#{counts.("judged")} valid=#{counts.("valid")} refused=#{counts.("refused")} forged=#{counts.("forged")} late_frames=#{counts.("late_frames")} ticks_skipped=#{counts.("skipped")} relays=#{relays} people=#{people} relay_refused=#{relay_refused} worst_relay_overruns=#{worst_over} loader_slow_passes=#{Enum.sum(slow)}")
    if blind != [], do: IO.puts("BLIND #{Enum.join(blind, ", ")}")

    cond do
      control == "" and seeing == 12 -> IO.puts("RESULT: PASS")
      control == "" -> IO.puts("RESULT: FAIL #{seeing} of 12 pairs see each other")
      seeing < 12 -> IO.puts("RESULT: FAIL the planted #{control} left #{seeing} of 12 pairs seeing")
      true -> IO.puts("RESULT: ERROR the planted #{control} was not caught")
    end
  end

  defp rows(path) do
    case File.read(path) do
      {:ok, bin} -> for <<row::binary-size(@row * 8) <- bin>>, into: %{}, do: (fn [t | rest] -> {trunc(t), rest} end).(for <<x::float-little-64 <- row>>, do: x)
      _ -> %{}
    end
  end

  defp dist([a, b, c], [x, y, z]), do: :math.sqrt((a - x) ** 2 + (b - y) ** 2 + (c - z) ** 2) * 1000.0

  defp fail(msg) do
    IO.puts("RESULT: ERROR " <> msg)
    System.halt(2)
  end
end

Clients.main(System.argv())
