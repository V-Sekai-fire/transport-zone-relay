# Replays the router model's recorded trace against the Mojo relay.
# Prints "RELAY records=<n> RESULT: PASS", or the first record that differs.
from std.sys import argv
from zone_relay import Zone, Bytes


def u16(d: List[UInt8], o: Int) -> Int:
    return Int(d[o]) | (Int(d[o + 1]) << 8)


def i32(d: List[UInt8], o: Int) -> Int32:
    var v = (
        UInt32(d[o])
        | (UInt32(d[o + 1]) << 8)
        | (UInt32(d[o + 2]) << 16)
        | (UInt32(d[o + 3]) << 24)
    )
    return Int32(v.cast[DType.int32]())


def u32(d: List[UInt8], o: Int) -> UInt64:
    return UInt64(
        UInt32(d[o])
        | (UInt32(d[o + 1]) << 8)
        | (UInt32(d[o + 2]) << 16)
        | (UInt32(d[o + 3]) << 24)
    )


def kind_name(k: Int) -> String:
    if k == 1: return "join"
    if k == 2: return "leave"
    if k == 3: return "put"
    if k == 4: return "frame"
    if k == 5: return "tick"
    if k == 6: return "unread"
    if k == 7: return "person_at"
    return "none"


def fail(rec: Int, kind: Int, off: Int, want: Int, got: Int):
    print(
        "RELAY record=" + String(rec) + " kind=" + kind_name(kind)
        + " offset=" + String(off) + " want=" + String(want)
        + " got=" + String(got) + " RESULT: FAIL"
    )


def main() raises:
    var args = argv()
    var path = String(args[1])
    var flip_byte = -1  # --flip-answer=<offset>: plant a one-bit change
    if len(args) > 2:
        flip_byte = Int(String(args[2]))
    var d: List[UInt8]
    with open(path, "r") as f:
        d = f.read_bytes()
    if flip_byte >= 0:
        d[flip_byte] = d[flip_byte] ^ 1
    var magic = "RTRACE1\n"
    for i in range(8):
        if Int(d[i]) != Int(ord(StringSlice(magic)[byte=i : i + 1])):
            print("RELAY bad magic RESULT: FAIL")
            raise Error("bad magic")
    var z = Zone.create()
    var base = Int(d.unsafe_ptr())
    var o = 8
    var rec = 0
    var n = len(d)
    while o < n:
        var start = o
        var kind = Int(d[o])
        o += 1
        if kind == 1:
            var want = Int(i32(d, o + 4))
            var got = z.join(i32(d, o))
            o += 8
            if got != want:
                fail(rec, kind, start, want, got); raise Error("fail")
        elif kind == 2:
            var want = Int(d[o + 4])
            var got = z.leave(i32(d, o))
            o += 5
            if got != want:
                fail(rec, kind, start, want, got); raise Error("fail")
        elif kind == 3:
            var slot = Int(d[o]); var half = Int(d[o + 1]); var ln = u16(d, o + 2)
            var payload = Bytes(unsafe_from_address=base + o + 4)
            var want = Int(d[o + 4 + ln])
            var got = z.put(slot, half, payload, ln)
            o += 5 + ln
            if got != want:
                fail(rec, kind, start, want, got); raise Error("fail")
        elif kind == 4:
            var viewer = Int(d[o]); var k = Int(d[o + 1])
            var wl = u16(d, o + 2)
            var gl = z.frame_len(viewer, k)
            if wl != gl:
                fail(rec, kind, start, wl, gl); raise Error("fail")
            if gl > 0:
                var fa = z.frame_at(viewer, k)
                for i in range(gl):
                    if z.store[unsafe_offset = fa + i] != d[o + 4 + i]:
                        fail(rec, kind, start + 5 + i, Int(d[o + 4 + i]), Int(z.store[unsafe_offset = fa + i]))
                        raise Error("fail")
            o += 4 + wl
        elif kind == 5:
            var want = u32(d, o)
            var got = z.tick()
            o += 4
            if got != want:
                fail(rec, kind, start, Int(want), Int(got)); raise Error("fail")
        elif kind == 6:
            var want = u32(d, o)
            var got = z.unread()
            o += 4
            if got != want:
                fail(rec, kind, start, Int(want), Int(got)); raise Error("fail")
        elif kind == 7:
            var want = Int(i32(d, o + 1))
            var got = Int(z.person_at(Int(d[o])))
            o += 5
            if got != want:
                fail(rec, kind, start, want, got); raise Error("fail")
        else:
            fail(rec, 0, start, 0, kind); raise Error("fail")
        rec += 1
    z.destroy()
    print("RELAY records=" + String(rec) + " RESULT: PASS")
