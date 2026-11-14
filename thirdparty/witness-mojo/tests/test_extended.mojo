# Set, map, tuple, oneof, transform, bind and the check bindings. Each property
# is paired with a planted-false control that the same machinery must catch.
from witness.ladder import *
from witness.check import *
from std.collections import Set


def check(cond: Bool, name: String) raises:
    if cond:
        print("ok   " + name)
    else:
        print("FAIL " + name)
        raise Error("failed: " + name)


def show_int(n: Int) -> String:
    return String(n)


def _no_show[T: Value](x: T) -> String:
    return String()


# ---- set
def gen_int_set(mut r: Run, lvl: Level) -> Set[Int]:
    return gen_set[Int](r, lvl, gen_wide)


def gen_wide(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, 1000)


def gen_small(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, 3)


def gen_small_set(mut r: Run, lvl: Level) -> Set[Int]:
    return gen_set[Int](r, lvl, gen_small)


def p_set_small_values(s: Set[Int], mut r: Run) -> Bool:
    for e in s:
        if e < 0 or e > 3:
            return False
    return True


def p_set_at_most_four(s: Set[Int], mut r: Run) -> Bool:
    return len(s) <= 4


def p_set_under_three(s: Set[Int], mut r: Run) -> Bool:
    return len(s) < 3


def show_set(s: Set[Int]) -> String:
    return "set(" + String(len(s)) + ")"


# ---- map
def gen_int_map(mut r: Run, lvl: Level) -> Dict[Int, Int]:
    return gen_map[Int, Int](r, lvl, gen_small, gen_wide)


def p_map_keys_small(m: Dict[Int, Int], mut r: Run) -> Bool:
    for k in m.keys():
        if k < 0 or k > 3:
            return False
    return True


def p_map_values_wide(m: Dict[Int, Int], mut r: Run) -> Bool:
    for item in m.items():
        if item.value < 0 or item.value > 1000:
            return False
    return True


def p_map_at_most_four(m: Dict[Int, Int], mut r: Run) -> Bool:
    return len(m) <= 4


def p_map_under_two(m: Dict[Int, Int], mut r: Run) -> Bool:
    return len(m) < 2


# ---- tuples
def gen_tri(mut r: Run, lvl: Level) -> Triple[Int, Bool, Int]:
    return gen_triple[Int, Bool, Int](r, lvl, gen_small, gen_bool, gen_wide)


def p_tri_in_range(t: Triple[Int, Bool, Int], mut r: Run) -> Bool:
    return t.first >= 0 and t.first <= 3 and t.third >= 0 and t.third <= 1000


def p_tri_third_small(t: Triple[Int, Bool, Int], mut r: Run) -> Bool:
    return t.third < 10


def shrink_tri(t: Triple[Int, Bool, Int]) -> List[Triple[Int, Bool, Int]]:
    return shrink_triple[Int, Bool, Int](t, shrink_int, shrink_bool, shrink_int)


def show_tri(t: Triple[Int, Bool, Int]) -> String:
    return "(" + String(t.first) + ", " + String(t.second) + ", " + String(t.third) + ")"


def gen_quad_ints(mut r: Run, lvl: Level) -> Quad[Int, Int, Int, Int]:
    return gen_quad[Int, Int, Int, Int](r, lvl, gen_small, gen_small, gen_small, gen_wide)


def p_quad_fourth_small(t: Quad[Int, Int, Int, Int], mut r: Run) -> Bool:
    return t.fourth < 10


def shrink_quad_ints(t: Quad[Int, Int, Int, Int]) -> List[Quad[Int, Int, Int, Int]]:
    return shrink_quad[Int, Int, Int, Int](t, shrink_int, shrink_int, shrink_int, shrink_int)


def show_quad(t: Quad[Int, Int, Int, Int]) -> String:
    return "(" + String(t.first) + ", " + String(t.second) + ", " + String(t.third) + ", " + String(t.fourth) + ")"


# ---- oneof, transform, bind
def gen_low(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, 9)


def gen_high(mut r: Run, lvl: Level) -> Int:
    return r.int_range(100, 109)


def gen_either(mut r: Run, lvl: Level) -> Int:
    var gens = List[Gen[Int]]()
    gens.append(gen_low)
    gens.append(gen_high)
    return gen_oneof[Int](r, lvl, gens)


def p_low_or_high(n: Int, mut r: Run) -> Bool:
    r.classify(n < 50, "low")
    r.classify(n >= 50, "high")
    return (n >= 0 and n <= 9) or (n >= 100 and n <= 109)


def p_always_low(n: Int, mut r: Run) -> Bool:
    return n < 50


def double(n: Int) -> Int:
    return n * 2


def gen_doubled(mut r: Run, lvl: Level) -> Int:
    return gen_transform[Int, Int](r, lvl, gen_wide, double)


def p_is_even(n: Int, mut r: Run) -> Bool:
    return n % 2 == 0


def p_is_odd(n: Int, mut r: Run) -> Bool:
    return n % 2 == 1


# bind: draw a bound b in 1..5, then a value below b.
def gen_below(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, 3)


def gen_bound(mut r: Run, lvl: Level) -> Int:
    return r.int_range(1, 5)


def gen_zero_to_nine(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, 9)


def gen_up_to_ten(mut r: Run, lvl: Level) -> Int:
    return r.int_range(10, 10)


def pick_gen(b: Int) -> Gen[Int]:
    if b <= 3:
        return gen_zero_to_nine
    return gen_up_to_ten


def gen_dependent(mut r: Run, lvl: Level) -> Int:
    return gen_bind[Int, Int](r, lvl, gen_bound, pick_gen)


def p_dependent_rule(n: Int, mut r: Run) -> Bool:
    return n >= 0 and n <= 10


def p_never_ten(n: Int, mut r: Run) -> Bool:
    return n != 10


def p_never_in_nine(n: Int, mut r: Run) -> Bool:
    return n > 9


def raises_for(held: Bool) -> Bool:
    # True when prop_check raised, as it must for a falsified property.
    try:
        if held:
            prop_check[Int]("holds", gen_low, p_nonneg)
        else:
            prop_check[Int]("fails", gen_low, p_false)
    except e:
        return True
    return False


def p_nonneg(n: Int, mut r: Run) -> Bool:
    return n >= 0


def p_false(n: Int, mut r: Run) -> Bool:
    return False


def main() raises:
    var t = resolve[Set[Int]]("set values", gen_small_set, p_set_small_values, no_shrink[Set[Int]], show_set, 0x11)
    check(t.outcome == Outcome.PROVABLY_NONE, "gen_set draws only from its element generator")
    t = resolve[Set[Int]]("set size", gen_small_set, p_set_at_most_four, no_shrink[Set[Int]], show_set, 0x11)
    check(t.outcome == Outcome.PROVABLY_NONE, "gen_set collapses duplicates: 0..3 gives at most 4 members")
    t = resolve[Set[Int]]("set under three", gen_small_set, p_set_under_three, shrink_set[Int], show_set, 0x11)
    check(t.outcome == Outcome.FOUND and t.message.find("minimum=set(3)") >= 0, "falsifiability: a set of 3 is caught and shrinks to 3 members")
    var ss = shrink_set[Int](Set[Int](1, 2, 3))
    check(len(ss) == 3 and len(ss[0]) == 2 and len(ss[1]) == 2 and len(ss[2]) == 2, "shrink_set drops one member at a time")
    check(len(shrink_set[Int](Set[Int]())) == 0, "shrink_set of empty is empty")

    var tm = resolve[Dict[Int, Int]]("map keys", gen_int_map, p_map_keys_small, no_shrink[Dict[Int, Int]], _no_show[Dict[Int, Int]], 0x12)
    check(tm.outcome == Outcome.PROVABLY_NONE, "gen_map keys come from the key generator")
    tm = resolve[Dict[Int, Int]]("map values", gen_int_map, p_map_values_wide, no_shrink[Dict[Int, Int]], _no_show[Dict[Int, Int]], 0x12)
    check(tm.outcome == Outcome.PROVABLY_NONE, "gen_map values come from the value generator")
    tm = resolve[Dict[Int, Int]]("map size", gen_int_map, p_map_at_most_four, no_shrink[Dict[Int, Int]], _no_show[Dict[Int, Int]], 0x12)
    check(tm.outcome == Outcome.PROVABLY_NONE, "gen_map keeps one entry per key")
    tm = resolve[Dict[Int, Int]]("map under two", gen_int_map, p_map_under_two, shrink_map[Int, Int], _no_show[Dict[Int, Int]], 0x12)
    check(tm.outcome == Outcome.FOUND, "falsifiability: a map of 2 entries is caught")
    var m3 = Dict[Int, Int]()
    m3[1] = 10
    m3[2] = 20
    var sm = shrink_map[Int, Int](m3)
    check(len(sm) == 2 and len(sm[0]) == 1 and len(sm[1]) == 1 and (1 in sm[0]) != (1 in sm[1]), "shrink_map drops one entry at a time")

    var tt = resolve[Triple[Int, Bool, Int]]("triple range", gen_tri, p_tri_in_range, shrink_tri, show_tri, 0x13)
    check(tt.outcome == Outcome.PROVABLY_NONE, "gen_triple fills each slot from its generator")
    tt = resolve[Triple[Int, Bool, Int]]("triple third", gen_tri, p_tri_third_small, shrink_tri, show_tri, 0x13)
    check(tt.outcome == Outcome.FOUND and tt.message.find("minimum=(0, False, 1") >= 0, "a triple shrinks the irrelevant slots to 0 and False, the third to 10..19")
    var tq = resolve[Quad[Int, Int, Int, Int]]("quad fourth", gen_quad_ints, p_quad_fourth_small, shrink_quad_ints, show_quad, 0x14)
    check(tq.outcome == Outcome.FOUND and tq.message.find("minimum=(0, 0, 0, 1") >= 0, "a quad shrinks the irrelevant slots to 0, the fourth to 10..19")
    var st = shrink_triple[Int, Bool, Int](Triple[Int, Bool, Int](4, True, 6), shrink_int, shrink_bool, shrink_int)
    check(len(st) == 2 + 1 + 2 and st[0].first == 0 and st[2].second == False and st[3].third == 0, "shrink_triple orders slot 1, slot 2, slot 3")

    var to = resolve[Int]("oneof", gen_either, p_low_or_high, no_shrink[Int], show_int, 0x15)
    check(to.outcome == Outcome.PROVABLY_NONE and to.message.find("low ") >= 0 and to.message.find("high ") >= 0, "gen_oneof reaches every generator and none else")
    to = resolve[Int]("oneof always low", gen_either, p_always_low, no_shrink[Int], show_int, 0x15)
    check(to.outcome == Outcome.FOUND, "falsifiability: gen_oneof's second generator is caught")

    to = resolve[Int]("transform", gen_doubled, p_is_even, no_shrink[Int], show_int, 0x16)
    check(to.outcome == Outcome.PROVABLY_NONE, "gen_transform applies the function to every draw")
    to = resolve[Int]("transform odd", gen_doubled, p_is_odd, no_shrink[Int], show_int, 0x16)
    check(to.outcome == Outcome.FOUND and to.level == 0, "falsifiability: a doubled value is never odd")

    to = resolve[Int]("bind", gen_dependent, p_dependent_rule, no_shrink[Int], show_int, 0x17)
    check(to.outcome == Outcome.PROVABLY_NONE, "gen_bind draws from the generator the first value picked")
    to = resolve[Int]("bind ten", gen_dependent, p_never_ten, no_shrink[Int], show_int, 0x17)
    check(to.outcome == Outcome.FOUND, "falsifiability: gen_bind reaches its second branch")
    to = resolve[Int]("bind nine", gen_dependent, p_never_in_nine, no_shrink[Int], show_int, 0x17)
    check(to.outcome == Outcome.FOUND, "falsifiability: gen_bind reaches its first branch")

    check(not raises_for(True), "prop_check returns when the property holds")
    check(raises_for(False), "falsifiability: prop_check raises when the property is falsified")
    var msg = String()
    try:
        prop_check_seed[Int]("fixed", gen_low, p_false, 0xABC)
    except e:
        msg = String(e)
    check(msg.find("property_seed=0xabc") >= 0, "prop_check_seed raises with the seed in the message")
    var shrunk = String()
    try:
        prop_check_shrink[Int]("shrinks", gen_wide, p_lt_ten, shrink_int, show_int)
    except e:
        shrunk = String(e)
    check(shrunk.find("minimum=") >= 0, "prop_check_shrink raises with the shrunk minimum")
    prop_check_seed[Int]("holds", gen_low, p_nonneg, 0x5)
    print("ALL PASS")


def p_lt_ten(n: Int, mut r: Run) -> Bool:
    return n < 10
