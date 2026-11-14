# Port of the witness-cpp suite. Each property is paired with a planted-false
# control (rule 2): the same machinery with a hostile predicate must be FOUND.
from witness.ladder import *



def gen_ints(mut r: Run, lvl: Level) -> List[Int]:
    return gen_list[Int](r, lvl, gen_int)


def show_ints(v: List[Int]) -> String:
    var s = String("[")
    for i in range(len(v)):
        if i > 0:
            s += ", "
        s += String(v[i])
    return s + "]"


def show_int(n: Int) -> String:
    return String(n)


def reverse_of(v: List[Int]) -> List[Int]:
    var a = List[Int]()
    for i in range(len(v) - 1, -1, -1):
        a.append(v[i])
    return a^


def same(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def p_involution(v: List[Int], mut r: Run) -> Bool:
    return same(reverse_of(reverse_of(v)), v)


def p_always_empty(v: List[Int], mut r: Run) -> Bool:
    return len(v) == 0


def p_short(v: List[Int], mut r: Run) -> Bool:
    return len(v) <= 100


def p_false_int(n: Int, mut r: Run) -> Bool:
    return False


def p_even_assumed(n: Int, mut r: Run) -> Bool:
    r.assume(n % 2 == 0)
    return n % 2 == 0


def p_never_assumed(n: Int, mut r: Run) -> Bool:
    r.assume(False)
    return False


def p_classified(n: Int, mut r: Run) -> Bool:
    r.classify(n > 0, "pos")
    r.classify(n <= 0, "nonpos")
    return True


def p_lt_ten(n: Int, mut r: Run) -> Bool:
    return n < 10


def gen_wide(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, 1000)


def gen_weighted(mut r: Run, lvl: Level) -> Int:
    var ws = List[Int]()
    ws.append(1)
    ws.append(0)
    ws.append(3)
    return gen_frequency(r, ws)


def p_never_one(i: Int, mut r: Run) -> Bool:
    return i != 1


def is_even(n: Int) -> Bool:
    return n % 2 == 0


def gen_evens(mut r: Run, lvl: Level) -> Int:
    return gen_filter[Int](r, lvl, gen_int, is_even)


def p_is_even(n: Int, mut r: Run) -> Bool:
    return n % 2 == 0


def gen_opt(mut r: Run, lvl: Level) -> Optional[Int]:
    return gen_optional[Int](r, lvl, gen_int)


def p_opt_some_or_none(o: Optional[Int], mut r: Run) -> Bool:
    r.classify(Bool(o), "some")
    r.classify(not o, "none")
    return True


def gen_str(mut r: Run, lvl: Level) -> String:
    return gen_string_of(r, lvl, "ab")


def p_ab_only(s: String, mut r: Run) -> Bool:
    for b in s.as_bytes():
        if b != 97 and b != 98:
            return False
    return True


def p_no_b(s: String, mut r: Run) -> Bool:
    for b in s.as_bytes():
        if b == 98:
            return False
    return True


def show_str(s: String) -> String:
    return "'" + s + "'"


def check(cond: Bool, name: String) raises:
    if cond:
        print("ok   " + name)
    else:
        print("FAIL " + name)
        raise Error("failed: " + name)


def main() raises:
    # --- core: a property holds, and its planted-false pair is caught at rung 0
    var t = resolve[List[Int]]("involution", gen_ints, p_involution, shrink_list[Int], show_ints)
    check(t.outcome == Outcome.PROVABLY_NONE, "reverse . reverse is identity")
    t = resolve[List[Int]]("always empty", gen_ints, p_always_empty, shrink_list[Int], show_ints)
    check(t.outcome == Outcome.FOUND and t.level == 0, "falsifiability: a planted-false property is caught at rung 0")

    # --- ladder: a defect that needs a big input is found only on a later rung
    t = resolve[List[Int]]("short", gen_ints, p_short, shrink_list[Int], show_ints, 0xBEEF)
    check(t.outcome == Outcome.FOUND and t.level == 2, "the ladder reaches rung 2 for a defect that needs 100+ elements")
    check(t.message.find("minimum=") >= 0 and t.message.find("shrunk") >= 0, "the found message carries a shrunk minimum")

    # --- reproducer seeds
    var a = resolve[Int]("always-false", gen_int, p_false_int, no_shrink[Int], show_int, 0xDEADBEEF)
    var b = resolve[Int]("always-false", gen_int, p_false_int, no_shrink[Int], show_int, 0xDEADBEEF)
    check(a.outcome == Outcome.FOUND and a.message == b.message, "same explicit seed reproduces the same message")
    a = resolve[Int]("always-false", gen_int, p_false_int, no_shrink[Int], show_int, 0x1111)
    b = resolve[Int]("always-false", gen_int, p_false_int, no_shrink[Int], show_int, 0x2222)
    check(a.message != b.message, "falsifiability: different seeds give different messages")
    t = resolve[Int]("always-false", gen_int, p_false_int, no_shrink[Int], show_int, 0xC0FFEE)
    check(t.message.find("property_seed=0xc0ffee") >= 0, "the FOUND message names the seed")
    check(parse_seed("0xff") == 255 and parse_seed("42") == 42 and parse_seed("zz") == 0 and parse_seed("") == 0, "parse_seed reads hex and decimal and refuses junk")
    check(hex_u64(0) == "0" and hex_u64(0xC0FFEE) == "c0ffee" and hex_u64(UInt64.MAX) == "ffffffffffffffff", "hex_u64")

    # --- shrinkers
    check(same(shrink_int(10), [0, 5]) and same(shrink_int(-7), [0, 7, -3]) and len(shrink_int(0)) == 0, "shrink_int candidates")
    check(len(shrink_bool(True)) == 1 and len(shrink_bool(False)) == 0, "shrink_bool")
    var sl = shrink_list[Int]([1, 2, 3])
    check(len(sl) == 4 and same(sl[0], [1]) and same(sl[1], [2, 3]) and same(sl[2], [1, 3]) and same(sl[3], [1, 2]), "shrink_list: first half, then each element removed")
    var ss = shrink_string("abc")
    check(len(ss) == 4 and ss[0] == "a" and ss[1] == "bc" and ss[2] == "ac" and ss[3] == "ab", "shrink_string")
    check(len(shrink_list[Int]([])) == 0, "shrink_list of empty is empty")
    var so = shrink_optional[Int](Optional[Int](4), shrink_int)
    check(len(so) == 3 and not so[0] and so[1].value() == 0 and so[2].value() == 2, "shrink_optional: None first, then the shrunk values")
    # a shrunk minimum still falsifies, and is not bigger than where it started
    t = resolve[Int]("lt ten", gen_wide, p_lt_ten, shrink_int, show_int, 0x77)
    check(t.outcome == Outcome.FOUND and t.message.find("minimum=") >= 0, "shrinking an int stops at a value that still falsifies")
    t = resolve[String]("no b", gen_str, p_no_b, shrink_string, show_str, 0x5)
    check(t.outcome == Outcome.FOUND and t.message.find("minimum='b'") >= 0, "a string shrinks to the one offending character")

    # --- assume and classify
    t = resolve[Int]("evens only", gen_int, p_even_assumed, no_shrink[Int], show_int, 0x9)
    check(t.outcome == Outcome.PROVABLY_NONE, "assume discards the odd trials and the rest hold")
    t = resolve[Int]("all assumed away", gen_int, p_never_assumed, no_shrink[Int], show_int, 0x9)
    check(t.outcome == Outcome.PROVABLY_NONE, "falsifiability: a property that assumes everything away is not a failure, it is capped")
    t = resolve[Int]("classified", gen_int, p_classified, no_shrink[Int], show_int, 0x9)
    check(t.message.find("classifications:") >= 0 and t.message.find("pos ") >= 0 and t.message.find("%") >= 0, "classify bins the trials")

    # --- generators
    t = resolve[Int]("frequency never picks a zero weight", gen_weighted, p_never_one, no_shrink[Int], show_int, 0x3)
    check(t.outcome == Outcome.PROVABLY_NONE, "gen_frequency never picks a zero-weight index")
    t = resolve[Int]("filter gives evens", gen_evens, p_is_even, no_shrink[Int], show_int, 0x3)
    check(t.outcome == Outcome.PROVABLY_NONE, "gen_filter yields only values that pass")
    t = resolve[Optional[Int]]("optional", gen_opt, p_opt_some_or_none, no_shrink[Optional[Int]], _no_show_opt, 0x3)
    check(t.message.find("some ") >= 0 and t.message.find("none ") >= 0, "gen_optional gives both Some and None")
    t = resolve[String]("alphabet", gen_str, p_ab_only, no_shrink[String], show_str, 0x3)
    check(t.outcome == Outcome.PROVABLY_NONE, "gen_string_of stays inside its alphabet")
    print("ALL PASS")


def _no_show_opt(o: Optional[Int]) -> String:
    return String()
