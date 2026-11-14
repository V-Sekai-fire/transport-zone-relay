# Property tests of the Mojo relay, with the witness ladder
# (thirdparty/witness-mojo, from V-Sekai-fire/contract-witness-cpp).
# Random op sequences replay against a fresh Zone; invariants hold after every op.
from witness.ladder import (
    Level, Run, Outcome, Trial, resolve, gen_list, gen_element, gen_frequency,
    shrink_list, hex_u64,
)
from zone_relay import Zone, Bytes, ZR_SLOTS, ZR_FRAME_MAX, ZR_FRAME_BYTES, ZR_SILENT_TICKS, ZR_OPEN_TICKS


# kind: 0 join, 1 leave, 2 put, 3 tick.
@fieldwise_init
struct Op(Copyable, Movable):
    var kind: Int
    var a: Int  # person, or slot, or tick count
    var b: Int  # half
    var n: Int  # frame length
    var fill: Int


def gen_op(mut r: Run, lvl: Level) -> Op:
    var w = List[Int]()
    w.append(3)
    w.append(1)
    w.append(8)
    w.append(3)
    var kind = gen_frequency(r, w)
    if kind == 0 or kind == 1:
        return Op(kind, r.int_range(0, 5), 0, 0, 0)
    if kind == 3:
        # mostly short, sometimes long enough to run a slot silent
        var count = r.int_range(1, 8) if r.int_range(0, 9) < 8 else r.int_range(60, 100)
        return Op(3, count, 0, 0, 0)
    var lens = List[Int]()
    lens.append(0)
    lens.append(1)
    lens.append(7)
    lens.append(ZR_FRAME_BYTES - 1)
    lens.append(ZR_FRAME_BYTES)
    lens.append(ZR_FRAME_BYTES + 1)
    lens.append(ZR_FRAME_MAX)
    lens.append(ZR_FRAME_MAX + 1)
    return Op(2, r.int_range(0, 5), r.int_range(0, 2), gen_element[Int](r, lens), r.int_range(1, 255))


def gen_ops(mut r: Run, lvl: Level) -> List[Op]:
    return gen_list[Op](r, lvl, gen_op)


def show_ops(v: List[Op]) -> String:
    var s = String("[")
    for i in range(len(v)):
        if i > 0:
            s += ", "
        var o = v[i].copy()
        if o.kind == 0:
            s += "join(" + String(o.a) + ")"
        elif o.kind == 1:
            s += "leave(" + String(o.a) + ")"
        elif o.kind == 2:
            s += "put(slot=" + String(o.a) + ",half=" + String(o.b) + ",len=" + String(o.n) + ")"
        else:
            s += "tick(" + String(o.a) + ")"
    return s + "]"


def slot_of(z: Zone, person: Int) -> Int:
    for s in range(ZR_SLOTS):
        if Int(z.person_at(s)) == person:
            return s
    return -1


def people_distinct(z: Zone) -> Bool:
    for s in range(ZR_SLOTS):
        var p = z.person_at(s)
        if p == -1:
            continue
        for t in range(s + 1, ZR_SLOTS):
            if z.person_at(t) == p:
                return False
    return True


def empty_slots_blank(z: Zone) -> Bool:
    for s in range(ZR_SLOTS):
        if z.person_at(s) != -1:
            continue
        for h in range(2):
            var at = s * 2 + h
            if Int(z.lens[unsafe_offset=at]) != ZR_FRAME_BYTES:
                return False
            for i in range(ZR_FRAME_BYTES):
                if z.store[unsafe_offset = at * ZR_FRAME_MAX + i] != 0:
                    return False
    return True


# `burst_div` is the tick spacing the burst bound uses; the relay's is 5.
# `planted` 1 = claim a refused frame is never counted (false).
def replay(ops: List[Op], burst_div: Int, planted: Int) -> Bool:
    var z = Zone.create()
    var last = List[Int](length=ZR_SLOTS, fill=0)
    var taken = List[Int](length=ZR_SLOTS * 2, fill=0)
    var due = List[Int](length=ZR_SLOTS * 2, fill=0)  # the documented due time of each half
    var ok = True
    for i in range(len(ops)):
        var o = ops[i].copy()
        if o.kind == 0:
            var was = slot_of(z, o.a)
            var s = z.join(Int32(o.a))
            if s >= 0:
                if Int(z.person_at(s)) != o.a:
                    ok = False
                if was < 0:
                    last[s] = Int(z.now)
        elif o.kind == 1:
            var was = slot_of(z, o.a)
            var left = z.leave(Int32(o.a))
            if (left == 1) != (was >= 0) or slot_of(z, o.a) >= 0:
                ok = False
        elif o.kind == 3:
            for _ in range(o.a):
                var before = List[Int](length=ZR_SLOTS, fill=0)
                for s in range(ZR_SLOTS):
                    before[s] = Int(z.person_at(s))
                var now0 = z.now
                var t = z.tick()
                if t != now0 + 1:
                    ok = False
                for s in range(ZR_SLOTS):
                    var silent = Int(t) - last[s] > ZR_SILENT_TICKS
                    if before[s] != -1 and silent and z.person_at(s) != -1:
                        ok = False  # a silent slot must be emptied on the tick it crosses
                    if z.person_at(s) != -1 and silent:
                        ok = False
                    if before[s] != -1 and not silent and z.person_at(s) == -1:
                        ok = False  # and a slot must not be emptied a tick early
        else:
            var buf = List[UInt8](length=o.n + 1, fill=UInt8(o.fill))
            var src = Bytes(unsafe_from_address=Int(buf.unsafe_ptr()))
            var valid = o.a < ZR_SLOTS and o.b < 2 and z.person_at(o.a) != -1
            var at = o.a * 2 + o.b
            var len0 = -1
            var first0 = 0
            var last0 = 0
            if o.a < ZR_SLOTS and o.b < 2:
                len0 = Int(z.lens[unsafe_offset=at])
                first0 = Int(z.store[unsafe_offset = at * ZR_FRAME_MAX])
                last0 = Int(z.store[unsafe_offset = at * ZR_FRAME_MAX + ZR_FRAME_MAX - 1])
            var unread0 = z.unread()
            var got = z.put(o.a, o.b, src, o.n)
            _ = len(buf)  # keep the buffer alive until the put has copied it
            if valid:
                # the documented rule: refused while now is more than 5 ticks short of the due time
                var early = Int(z.now) + ZR_OPEN_TICKS < due[at]
                var expected = (not early) and o.n <= ZR_FRAME_MAX
                if (got == 1) != expected:
                    ok = False
                if got == 1:
                    due[at] = (due[at] if due[at] > Int(z.now) else Int(z.now)) + ZR_OPEN_TICKS
            if got == 1:
                if not valid or o.n > ZR_FRAME_MAX or z.unread() != unread0:
                    ok = False
                taken[at] += 1
                last[o.a] = Int(z.now)
                if Int(z.lens[unsafe_offset=at]) != o.n:
                    ok = False
                # every viewer is handed exactly the bytes that were put
                for v in range(ZR_SLOTS):
                    if v == o.a:
                        continue
                    var k = (o.a - 1 if o.a > v else o.a) * 2 + o.b
                    if z.frame_len(v, k) != o.n:
                        ok = False
                    var fa = z.frame_at(v, k)
                    for j in range(o.n):
                        if z.store[unsafe_offset = fa + j] != UInt8(o.fill):
                            ok = False
                if taken[at] > Int(z.now) // burst_div + 2:
                    ok = False
            else:
                if not valid:
                    if z.unread() != unread0:
                        ok = False  # a put to nobody is not counted
                elif o.n <= ZR_FRAME_MAX:
                    if z.unread() != unread0 + 1:
                        ok = False  # a too-early frame is counted
                if len0 >= 0:
                    if Int(z.lens[unsafe_offset=at]) != len0 or Int(z.store[unsafe_offset = at * ZR_FRAME_MAX]) != first0 or Int(z.store[unsafe_offset = at * ZR_FRAME_MAX + ZR_FRAME_MAX - 1]) != last0:
                        ok = False  # a refused frame leaves the store alone
                if planted == 1 and z.unread() != unread0:
                    ok = False
        if not people_distinct(z):
            ok = False
        if not ok:
            break
    if ok and not empty_slots_blank(z):
        ok = False
    z.destroy()
    return ok


def p_relay(ops: List[Op], mut r: Run) -> Bool:
    return replay(ops, ZR_OPEN_TICKS, 0)


def p_planted_burst(ops: List[Op], mut r: Run) -> Bool:
    return replay(ops, ZR_OPEN_TICKS + 1, 0)  # claims one frame in six ticks


def p_planted_uncounted(ops: List[Op], mut r: Run) -> Bool:
    return replay(ops, ZR_OPEN_TICKS, 1)  # claims a refused frame is never counted


def check(cond: Bool, name: String, msg: String) raises:
    print(("ok   " if cond else "FAIL ") + name)
    print("       " + msg)
    if not cond:
        raise Error("failed: " + name)


def main() raises:
    var t = resolve[List[Op]]("relay invariants hold over random op sequences", gen_ops, p_relay, shrink_list[Op], show_ops)
    check(t.outcome == Outcome.PROVABLY_NONE, "the relay keeps every invariant over the ladder", t.message)
    var c1 = resolve[List[Op]]("planted: one frame in six ticks", gen_ops, p_planted_burst, shrink_list[Op], show_ops, 0xA11CE)
    check(c1.outcome == Outcome.FOUND, "falsifiability: a wrong burst bound is caught", c1.message)
    var c2 = resolve[List[Op]]("planted: refused frames are never counted", gen_ops, p_planted_uncounted, shrink_list[Op], show_ops, 0xA11CE)
    check(c2.outcome == Outcome.FOUND, "falsifiability: a wrong unread claim is caught", c2.message)
    print("PROPS PASS")
