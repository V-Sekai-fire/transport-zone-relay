defmodule ZoneRelay.TraceTest do
  use ExUnit.Case, async: true
  alias ZoneRelay.Nif

  @trace Path.expand("../src/testdata/zone_relay.trace", __DIR__)

  # Replays the router model's trace through the Mojo NIF. Returns
  # {:ok, records} or {:fail, record, kind, offset, want, got}.
  defp replay(bin) do
    <<"RTRACE1\n", rest::binary>> = bin
    replay(Nif.new(), rest, 8, 0)
  end

  defp replay(_z, <<>>, _off, n), do: {:ok, n}

  defp replay(z, <<1, person::signed-32-little, want::signed-32-little, r::binary>>, off, n),
    do: check(z, :join, off, n, want, Nif.join(z, person), r, 9)

  defp replay(z, <<2, person::signed-32-little, want, r::binary>>, off, n),
    do: check(z, :leave, off, n, want, Nif.leave(z, person), r, 6)

  defp replay(z, <<3, slot, half, len::16-little, p::binary-size(len), want, r::binary>>, off, n),
    do: check(z, :put, off, n, want, Nif.put(z, slot, half, p), r, 6 + len)

  defp replay(z, <<4, viewer, k, len::16-little, want::binary-size(len), r::binary>>, off, n) do
    got = Nif.frame(z, viewer, k)

    if got == want,
      do: replay(z, r, off + 5 + len, n + 1),
      else: {:fail, n, :frame, off, byte_size(want), byte_size(got)}
  end

  defp replay(z, <<5, want::32-little, r::binary>>, off, n),
    do: check(z, :tick, off, n, want, Nif.tick(z), r, 5)

  defp replay(z, <<6, want::32-little, r::binary>>, off, n),
    do: check(z, :unread, off, n, want, Nif.unread(z), r, 5)

  defp replay(z, <<7, slot, want::signed-32-little, r::binary>>, off, n),
    do: check(z, :person_at, off, n, want, Nif.person_at(z, slot), r, 6)

  defp replay(_z, _bad, off, n), do: {:fail, n, :none, off, 0, 0}

  defp check(z, _kind, off, n, want, want, r, size), do: replay(z, r, off + size, n + 1)
  defp check(_z, kind, off, n, want, got, _r, _size), do: {:fail, n, kind, off, want, got}

  test "the Mojo relay answers every record of the router model's trace" do
    assert {:ok, 1471} = replay(File.read!(@trace))
  end

  test "planted controls: one flipped bit makes the replay fail" do
    bin = File.read!(@trace)

    for off <- [600, 100_000, 1_000_000, byte_size(bin) - 1] do
      <<head::binary-size(^off), b, tail::binary>> = bin
      assert {:fail, _rec, _kind, _off, _want, _got} = replay(<<head::binary, Bitwise.bxor(b, 1), tail::binary>>)
    end
  end

  test "a zone is its own resource" do
    a = Nif.new()
    b = Nif.new()
    assert Nif.join(a, 7) == 0
    assert Nif.person_at(b, 0) == -1
    assert_raise ArgumentError, fn -> Nif.join(:not_a_zone, 1) end
    assert_raise ArgumentError, fn -> Nif.put(a, 0, 0, :nope) end
  end
end
