defmodule ZoneRelay.ServerTest do
  use ExUnit.Case

  @port 41_900

  defp client do
    {:ok, s} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    s
  end

  defp frame(tag), do: :binary.copy(<<tag>>, 1200)

  test "two clients on two sockets: each gets the other's frames, by half" do
    {:ok, srv} = ZoneRelay.Server.start_link(port: @port)
    a = client()
    b = client()

    # b is heard first so a is seated; then a sends both halves.
    :ok = :gen_udp.send(b, {127, 0, 0, 1}, @port, frame(?B))
    :ok = :gen_udp.send(a, {127, 0, 0, 1}, @port, frame(?A))
    :ok = :gen_udp.send(a, {127, 0, 0, 1}, @port + 1, frame(?a))

    # a's first-half frame, then second-half frame, arrive at b from the same sockets.
    assert {:ok, {_, @port, f1}} = :gen_udp.recv(b, 0, 1000)
    assert f1 == frame(?A)
    assert {:ok, {_, p2, f2}} = :gen_udp.recv(b, 0, 1000)
    assert p2 == @port + 1 and f2 == frame(?a)

    # b's first frame went out while a was not seated. Its second one (a burst
    # of two is allowed) is relayed to a.
    :ok = :gen_udp.send(b, {127, 0, 0, 1}, @port, frame(?B))
    assert {:ok, {_, @port, fb}} = :gen_udp.recv(a, 0, 1000)
    assert fb == frame(?B)

    r = ZoneRelay.Server.report(srv)
    assert r.people == 2 and r.frames_in == 4 and r.datagrams_out == 3 and r.refused == 0
    ZoneRelay.Server.stop(srv)
  end

  test "a flood in one interval is refused and counted, not relayed" do
    {:ok, srv} = ZoneRelay.Server.start_link(port: @port + 10)
    a = client()
    b = client()
    :ok = :gen_udp.send(b, {127, 0, 0, 1}, @port + 10, frame(?B))
    for _ <- 1..10, do: :gen_udp.send(a, {127, 0, 0, 1}, @port + 10, frame(?A))
    Process.sleep(100)
    r = ZoneRelay.Server.report(srv)
    assert r.refused >= 7 and r.unread >= 7
    ZoneRelay.Server.stop(srv)
  end

  test "the tick runs at about 64 Hz" do
    {:ok, srv} = ZoneRelay.Server.start_link(port: @port + 20)
    Process.sleep(1000)
    %{ticks: t} = ZoneRelay.Server.report(srv)
    assert t in 60..68
    ZoneRelay.Server.stop(srv)
  end
end
