defmodule FrameSizes do
  @frame 1200
  @sends_per_s 64 / 6
  @engine_header 5
  @budget 8192
  @burst 12288
  @cap 18432

  def main(["--self-test", work]) do
    File.mkdir_p!(work)
    seed = :rand.seed(:exsss, {20, 26, 1113})
    {random, _} = Enum.map_reduce(1..@frame, seed, fn _, s -> :rand.uniform_s(256, s) |> then(fn {v, s} -> {v - 1, s} end) end)
    random = :erlang.list_to_binary(random)
    dummy = :binary.copy(<<0>>, @frame)
    dict = Path.join(work, "self-dict.bin")
    File.write!(dict, :binary.copy(<<0>>, 16 * @frame))
    r = zstd(random, dict, 19, work)
    d = zstd(dummy, dict, 19, work)
    IO.puts("SELF random frame #{r} bytes, dummy frame #{d} bytes")
    ok = r >= @frame and d < 64
    IO.puts("RESULT: #{if ok, do: "PASS", else: "FAIL a random frame shrank or a dummy frame did not"}")
    System.halt(if ok, do: 0, else: 1)
  end

  def main([dir, work | opts]) do
    every = opts |> Enum.find_value(4, fn "--every=" <> n -> String.to_integer(n); _ -> nil end)
    names = dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".frames")) |> Enum.sort()
    {train, held} = names |> Enum.with_index() |> Enum.split_with(fn {_, i} -> rem(i, 2) == 0 end)
    train = Enum.map(train, &elem(&1, 0))
    held = Enum.map(held, &elem(&1, 0))
    File.mkdir_p!(work)
    train_frames = Enum.flat_map(train, &frames(dir, &1))
    IO.puts("streams: #{length(train)} build the dictionary (#{length(train_frames)} frames), #{length(held)} held out")

    dicts =
      for size <- [16_384, 65_536, 262_144] do
        want = div(size, @frame)
        step = max(div(length(train_frames), want), 1)
        step = if rem(step, 2) == 0, do: step + 1, else: step
        path = Path.join(work, "dict-#{size}.bin")
        File.write!(path, train_frames |> Enum.take_every(step) |> Enum.take(want) |> IO.iodata_to_binary())
        {"fixed #{div(size, 1024)} KiB", path}
      end

    samples =
      for name <- held, sends = pairs(frames(dir, name)), {{a, b}, i} <- Enum.with_index(sends), i > 0, rem(i, every) == 1 do
        {a, b, Enum.at(sends, i - 1)}
      end

    IO.puts("held-out sends measured: #{length(samples)}")
    IO.puts("dictionary\tlevel\tbytes a send\tlargest\tbytes a Packet\tup B/s\tdown B/s\tagainst #{@budget}")
    configs = [{"none", nil, 3}] ++ for({n, p} <- dicts, l <- [3, 19], do: {n, p, l}) ++ [{"the send before", :prev, 3}, {"the send before", :prev, 19}]

    for {name, dict, level} <- configs do
      sizes =
        samples
        |> Task.async_stream(fn {a, b, {pa, pb}} ->
          {da, db} = if dict == :prev, do: {pa, pb}, else: {dict, dict}
          zstd(a, da, level, work) + zstd(b, db, level, work) + 2 * @engine_header
        end, max_concurrency: 10, timeout: :infinity)
        |> Enum.map(fn {:ok, n} -> n end)

      mean = Enum.sum(sizes) / length(sizes)
      up = round(mean * @sends_per_s)
      verdict = cond do
        up <= @budget -> "under"
        up <= @burst -> "over, under the burst #{@burst}"
        up <= @cap -> "over, under the cap #{@cap}"
        true -> "over the cap"
      end
      IO.puts("#{name}\t#{level}\t#{Float.round(mean, 1)}\t#{Enum.max(sizes)}\t#{Float.round(mean / 21, 1)}\t#{up}\t#{up * 3}\t#{verdict}")
    end
  end

  def main(_) do
    IO.puts(:stderr, "usage: frame_sizes.exs <dir of .frames> <work dir> [--every=N] | --self-test <work dir>")
    System.halt(2)
  end

  defp frames(dir, name), do: for(<<f::binary-size(@frame) <- File.read!(Path.join(dir, name))>>, do: f)

  defp pairs(frames), do: frames |> Enum.chunk_every(2, 2, :discard) |> Enum.map(fn [a, b] -> {a, b} end)

  defp zstd(frame, dict, level, work) do
    id = :erlang.unique_integer([:positive])
    src = Path.join(work, "f#{id}")
    File.write!(src, frame)

    {extra, temp} =
      cond do
        dict == nil -> {[], nil}
        byte_size(dict) == @frame and not String.printable?(dict) ->
          d = Path.join(work, "d#{id}")
          File.write!(d, dict)
          {["--patch-from=#{d}"], d}
        true -> {["--patch-from=#{dict}"], nil}
      end

    {out, 0} = System.cmd("zstd", ["-#{level}", "-q", "-c"] ++ extra ++ [src])
    File.rm(src)
    if temp, do: File.rm(temp)
    byte_size(out)
  end
end

FrameSizes.main(System.argv())
