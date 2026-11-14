# SPDX-License-Identifier: MIT
# witness-mojo: property-testing ladder for Mojo, ported from witness-cpp
# (V-Sekai-fire/contract-witness-cpp include/witness/ladder.h), which follows
# the Lean plausible-witness-dag ladder: a property is tried over rungs of
# growing budget, a falsifying input is shrunk, and the seed is reported.
#
# Differences from the C++ source, on purpose:
#   * No closures. A generator is `def(mut Run, Level) thin -> T`, a predicate is
#     `def(T, mut Run) thin -> Bool`; a function that needs a bound or a size takes
#     it as an argument and the caller writes the one-line generator.
#   * `Run` holds the RNG and the assume/classify/collect state, so no global.
#   * The RNG is SplitMix64, not mt19937_64. A seed reproduces a run in Mojo;
#     it does not reproduce a C++ run.

from std.os import getenv
from std.collections import Set
from std.time import perf_counter_ns

comptime Value = Copyable & Deinitable

# A generator: draws a T from the run's RNG at a rung.
comptime Gen[T: Value] = def(mut Run, Level) thin -> T


@fieldwise_init
struct Level(Copyable, Movable):
    var idx: Int
    var walk_steps: Int
    var fin_bound: Int
    var num_inst: Int


# The three rungs of the Lean defaults, verbatim.
def default_ladder() -> List[Level]:
    var out = List[Level]()
    out.append(Level(0, 64, 256, 200))
    out.append(Level(1, 512, 1024, 800))
    out.append(Level(2, 4000, 4096, 2000))
    return out^


@fieldwise_init
struct Outcome(ImplicitlyCopyable, Equatable):
    var value: Int
    comptime FOUND = Outcome(0)
    comptime PROVABLY_NONE = Outcome(1)
    comptime BUDGET_HIT = Outcome(2)

    def __eq__(self, other: Outcome) -> Bool:
        return self.value == other.value


@fieldwise_init
struct Verdict(ImplicitlyCopyable, Equatable):
    var value: Int
    comptime HOLD = Verdict(0)
    comptime FALSIFY = Verdict(1)
    comptime SKIP = Verdict(2)

    def __eq__(self, other: Verdict) -> Bool:
        return self.value == other.value


@fieldwise_init
struct Trial(Copyable, Movable):
    var outcome: Outcome
    var level: Int
    var trial_idx: Int
    var message: String


struct Ctx(Copyable, Movable):
    var verdict: Verdict
    var class_hits: Dict[String, Int]
    var class_order: List[String]
    var trials_counted: Int

    def __init__(out self):
        self.verdict = Verdict.HOLD
        self.class_hits = Dict[String, Int]()
        self.class_order = List[String]()
        self.trials_counted = 0


# One run of a property: the RNG, and what assume/classify/collect record.
struct Run(Movable):
    var state: UInt64
    var ctx: Ctx

    def __init__(out self, seed: UInt64):
        self.state = seed
        self.ctx = Ctx()

    def next_u64(mut self) -> UInt64:
        # SplitMix64.
        self.state += 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB
        return z ^ (z >> 31)

    # Uniform in lo..hi inclusive; hi <= lo gives lo.
    def int_range(mut self, lo: Int, hi: Int) -> Int:
        if hi <= lo:
            return lo
        var span = UInt64(hi - lo) + 1
        if span == 0:
            return Int(self.next_u64())
        return lo + Int(self.next_u64() % span)

    def float_range(mut self, lo: Float64, hi: Float64) -> Float64:
        var u = Float64(self.next_u64() >> 11) / Float64(1 << 53)
        return lo + (hi - lo) * u

    # Discard this trial. Discards are capped at ten times a rung's budget.
    def assume(mut self, cond: Bool):
        if not cond:
            self.ctx.verdict = Verdict.SKIP

    def classify(mut self, cond: Bool, label: String):
        if cond:
            self._hit(label)

    # Bin the trial by a rendered value.
    def collect(mut self, rendered: String):
        self._hit(rendered)

    def _hit(mut self, label: String):
        var cur = self.ctx.class_hits.get(label)
        if cur:
            self.ctx.class_hits[label] = cur.value() + 1
        else:
            self.ctx.class_hits[label] = 1
            self.ctx.class_order.append(label)


# -------------------------------------------------------------------
# Primitive generators. Sizes scale with the rung's fin_bound.
# -------------------------------------------------------------------

def _scale(lvl: Level) -> Int:
    var s = lvl.fin_bound // 32
    return s if s > 1 else 1


def gen_bool(mut r: Run, lvl: Level) -> Bool:
    return r.int_range(0, 1) == 1


# A printable ASCII code point, 32..126.
def gen_char(mut r: Run, lvl: Level) -> Int:
    return r.int_range(32, 126)


def gen_int(mut r: Run, lvl: Level) -> Int:
    var s = _scale(lvl)
    return r.int_range(-s, s)


def gen_uint(mut r: Run, lvl: Level) -> Int:
    return r.int_range(0, _scale(lvl))


def gen_int64(mut r: Run, lvl: Level) -> Int64:
    var s = lvl.fin_bound if lvl.fin_bound > 1 else 1
    return Int64(r.int_range(-s, s))


def gen_uint64(mut r: Run, lvl: Level) -> UInt64:
    var s = lvl.fin_bound if lvl.fin_bound > 1 else 1
    return UInt64(r.int_range(0, s))


def gen_float64(mut r: Run, lvl: Level) -> Float64:
    var s = Float64(lvl.fin_bound if lvl.fin_bound > 1 else 1)
    return r.float_range(-s, s)


def printable() -> String:
    var s = String()
    for c in range(32, 127):
        s += chr(c)
    return s^


# A string over a caller-supplied alphabet, length 0..fin_bound/32.
def gen_string_of(mut r: Run, lvl: Level, alphabet: String) -> String:
    var n = r.int_range(0, _scale(lvl))
    var out = String()
    var bytes = alphabet.as_bytes()
    if len(bytes) == 0:
        return out^
    for _ in range(n):
        out += chr(Int(bytes[r.int_range(0, len(bytes) - 1)]))
    return out^


def gen_string(mut r: Run, lvl: Level) -> String:
    return gen_string_of(r, lvl, printable())


# -------------------------------------------------------------------
# Containers and combinators. The element generator is a function value.
# -------------------------------------------------------------------

def gen_list[T: Value](
    mut r: Run, lvl: Level, elem: def(mut Run, Level) thin -> T
) -> List[T]:
    var n = r.int_range(0, _scale(lvl))
    var out = List[T]()
    for _ in range(n):
        out.append(elem(r, lvl))
    return out^


# Exactly n elements.
def gen_array[T: Value](
    mut r: Run, lvl: Level, n: Int, elem: def(mut Run, Level) thin -> T
) -> List[T]:
    var out = List[T]()
    for _ in range(n):
        out.append(elem(r, lvl))
    return out^


# None one time in four, as in the C++.
def gen_optional[T: Value](
    mut r: Run, lvl: Level, elem: def(mut Run, Level) thin -> T
) -> Optional[T]:
    if r.int_range(0, 3) == 0:
        return None
    return elem(r, lvl)


@fieldwise_init
struct Pair[A: Value, B: Value](Copyable, Movable):
    var first: Self.A
    var second: Self.B


# The two draws are sequenced a then b, so RNG use is stable.
def gen_pair[A: Value, B: Value](
    mut r: Run,
    lvl: Level,
    a_gen: def(mut Run, Level) thin -> A,
    b_gen: def(mut Run, Level) thin -> B,
) -> Pair[A, B]:
    var a = a_gen(r, lvl)
    var b = b_gen(r, lvl)
    return Pair[A, B](a^, b^)


# Distinct elements, up to fin_bound/32 draws (duplicates collapse, as in the C++).
def gen_set[T: KeyElement & Value](
    mut r: Run, lvl: Level, elem: def(mut Run, Level) thin -> T
) -> Set[T]:
    var n = r.int_range(0, _scale(lvl))
    var out = Set[T]()
    for _ in range(n):
        out.add(elem(r, lvl))
    return out^


# Up to fin_bound/32 key/value draws; a repeated key keeps its first value
# (the C++ emplace). Each pair draws key then value.
def gen_map[K: KeyElement & Value, V: Copyable & Deinitable](
    mut r: Run,
    lvl: Level,
    key_gen: def(mut Run, Level) thin -> K,
    value_gen: def(mut Run, Level) thin -> V,
) -> Dict[K, V]:
    var n = r.int_range(0, _scale(lvl))
    var out = Dict[K, V]()
    for _ in range(n):
        var k = key_gen(r, lvl)
        var v = value_gen(r, lvl)
        if k not in out:
            out[k^] = v^
    return out^


@fieldwise_init
struct Triple[A: Value, B: Value, C: Value](Copyable, Movable):
    var first: Self.A
    var second: Self.B
    var third: Self.C


@fieldwise_init
struct Quad[A: Value, B: Value, C: Value, D: Value](Copyable, Movable):
    var first: Self.A
    var second: Self.B
    var third: Self.C
    var fourth: Self.D


# Draws run left to right, so RNG use is stable.
def gen_triple[A: Value, B: Value, C: Value](
    mut r: Run,
    lvl: Level,
    a_gen: def(mut Run, Level) thin -> A,
    b_gen: def(mut Run, Level) thin -> B,
    c_gen: def(mut Run, Level) thin -> C,
) -> Triple[A, B, C]:
    var a = a_gen(r, lvl)
    var b = b_gen(r, lvl)
    var c = c_gen(r, lvl)
    return Triple[A, B, C](a^, b^, c^)


def gen_quad[A: Value, B: Value, C: Value, D: Value](
    mut r: Run,
    lvl: Level,
    a_gen: def(mut Run, Level) thin -> A,
    b_gen: def(mut Run, Level) thin -> B,
    c_gen: def(mut Run, Level) thin -> C,
    d_gen: def(mut Run, Level) thin -> D,
) -> Quad[A, B, C, D]:
    var a = a_gen(r, lvl)
    var b = b_gen(r, lvl)
    var c = c_gen(r, lvl)
    var d = d_gen(r, lvl)
    return Quad[A, B, C, D](a^, b^, c^, d^)


# Uniform pick among generators of one type, then one draw from the pick.
def gen_oneof[T: Value](
    mut r: Run, lvl: Level, gens: List[Gen[T]]
) -> T:
    var i = r.int_range(0, len(gens) - 1)
    return gens[i](r, lvl)


# Map a function over a generator's output.
def gen_transform[In: Value, Out: Value](
    mut r: Run,
    lvl: Level,
    gen: def(mut Run, Level) thin -> In,
    f: def(In) thin -> Out,
) -> Out:
    return f(gen(r, lvl))


# Dependent generation: draw from `gen`, hand the value to `fn`, which names a
# second generator, then draw from that one.
def gen_bind[In: Value, Out: Value](
    mut r: Run,
    lvl: Level,
    gen: def(mut Run, Level) thin -> In,
    f: def(In) thin -> Gen[Out],
) -> Out:
    var seed_value = gen(r, lvl)
    var next_gen = f(seed_value^)
    return next_gen(r, lvl)


# Uniform pick of one value.
def gen_element[T: Value](mut r: Run, values: List[T]) -> T:
    return values[r.int_range(0, len(values) - 1)].copy()


# Index chosen with probability proportional to its weight.
def gen_frequency(mut r: Run, weights: List[Int]) -> Int:
    var total = 0
    for w in weights:
        total += w
    var pick = r.int_range(0, (total - 1) if total > 1 else 0)
    var acc = 0
    for i in range(len(weights)):
        acc += weights[i]
        if pick < acc:
            return i
    return len(weights) - 1


# Resample up to `retries` times until `pred` holds. On exhaustion the last
# draw is returned and the trial is marked SKIP.
def gen_filter[T: Value](
    mut r: Run,
    lvl: Level,
    gen: def(mut Run, Level) thin -> T,
    pred: def(T) thin -> Bool,
    retries: Int = 32,
) -> T:
    var v = gen(r, lvl)
    for _ in range(retries):
        if pred(v):
            return v^
        v = gen(r, lvl)
    if not pred(v):
        r.ctx.verdict = Verdict.SKIP
    return v^


# -------------------------------------------------------------------
# Shrinkers. Each returns smaller candidates, simplest first.
# -------------------------------------------------------------------

def shrink_bool(b: Bool) -> List[Bool]:
    var out = List[Bool]()
    if b:
        out.append(False)
    return out^


# Halving truncates toward zero, as C++ division does.
def _half(n: Int) -> Int:
    return n // 2 if n >= 0 else -((-n) // 2)


def shrink_int(n: Int) -> List[Int]:
    var out = List[Int]()
    if n != 0:
        out.append(0)
    if n < 0:
        out.append(-n)
    var halved = _half(n)
    if halved != n:
        out.append(halved)
    return out^


def shrink_int64(n: Int64) -> List[Int64]:
    var out = List[Int64]()
    for c in shrink_int(Int(n)):
        out.append(Int64(c))
    return out^


def shrink_uint64(n: UInt64) -> List[UInt64]:
    var out = List[UInt64]()
    if n != 0:
        out.append(0)
    var halved = n // 2
    if halved != n:
        out.append(halved)
    return out^


def shrink_float64(x: Float64) -> List[Float64]:
    var out = List[Float64]()
    if x != 0.0:
        out.append(0.0)
    if x < 0.0:
        out.append(-x)
    var halved = x / 2.0
    if halved != x:
        out.append(halved)
    return out^


# First half, then each character removed.
def shrink_string(s: String) -> List[String]:
    var out = List[String]()
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        return out^
    if n > 1:
        var half = String()
        for i in range(n // 2):
            half += chr(Int(b[i]))
        out.append(half^)
    for i in range(n):
        var smaller = String()
        for j in range(n):
            if j != i:
                smaller += chr(Int(b[j]))
        out.append(smaller^)
    return out^


# First half, then each element removed. Elements are not shrunk.
def shrink_list[T: Value](v: List[T]) -> List[List[T]]:
    var out = List[List[T]]()
    var n = len(v)
    if n == 0:
        return out^
    if n > 1:
        var half = List[T]()
        for i in range(n // 2):
            half.append(v[i].copy())
        out.append(half^)
    for i in range(n):
        var smaller = List[T]()
        for j in range(n):
            if j != i:
                smaller.append(v[j].copy())
        out.append(smaller^)
    return out^


def shrink_pair[A: Value, B: Value](
    p: Pair[A, B],
    a_shrink: def(A) thin -> List[A],
    b_shrink: def(B) thin -> List[B],
) -> List[Pair[A, B]]:
    var out = List[Pair[A, B]]()
    var a_c = a_shrink(p.first)
    for i in range(len(a_c)):
        out.append(Pair[A, B](a_c[i].copy(), p.second.copy()))
    var b_c = b_shrink(p.second)
    for i in range(len(b_c)):
        out.append(Pair[A, B](p.first.copy(), b_c[i].copy()))
    return out^


def shrink_optional[T: Value](
    x: Optional[T], t_shrink: def(T) thin -> List[T]
) -> List[Optional[T]]:
    var out = List[Optional[T]]()
    if x:
        out.append(None)
        var c = t_shrink(x.value())
        for i in range(len(c)):
            out.append(Optional[T](c[i].copy()))
    return out^


# Each element removed, in iteration order.
def shrink_set[T: KeyElement & Value](s: Set[T]) -> List[Set[T]]:
    var out = List[Set[T]]()
    var items = List[T]()
    for e in s:
        items.append(e.copy())
    for i in range(len(items)):
        var smaller = Set[T]()
        for j in range(len(items)):
            if j != i:
                smaller.add(items[j].copy())
        out.append(smaller^)
    return out^


# Each entry removed, in iteration order. Values are not shrunk, as in the C++.
def shrink_map[K: KeyElement & Value, V: Copyable & Deinitable](
    m: Dict[K, V]
) -> List[Dict[K, V]]:
    var out = List[Dict[K, V]]()
    var keys = List[K]()
    var vals = List[V]()
    for item in m.items():
        keys.append(item.key.copy())
        vals.append(item.value.copy())
    for i in range(len(keys)):
        var smaller = Dict[K, V]()
        for j in range(len(keys)):
            if j != i:
                smaller[keys[j].copy()] = vals[j].copy()
        out.append(smaller^)
    return out^


# Slot by slot: every shrink of the first, then of the second, and so on.
def shrink_triple[A: Value, B: Value, C: Value](
    t: Triple[A, B, C],
    a_shrink: def(A) thin -> List[A],
    b_shrink: def(B) thin -> List[B],
    c_shrink: def(C) thin -> List[C],
) -> List[Triple[A, B, C]]:
    var out = List[Triple[A, B, C]]()
    var a_c = a_shrink(t.first)
    for i in range(len(a_c)):
        out.append(Triple[A, B, C](a_c[i].copy(), t.second.copy(), t.third.copy()))
    var b_c = b_shrink(t.second)
    for i in range(len(b_c)):
        out.append(Triple[A, B, C](t.first.copy(), b_c[i].copy(), t.third.copy()))
    var c_c = c_shrink(t.third)
    for i in range(len(c_c)):
        out.append(Triple[A, B, C](t.first.copy(), t.second.copy(), c_c[i].copy()))
    return out^


def shrink_quad[A: Value, B: Value, C: Value, D: Value](
    t: Quad[A, B, C, D],
    a_shrink: def(A) thin -> List[A],
    b_shrink: def(B) thin -> List[B],
    c_shrink: def(C) thin -> List[C],
    d_shrink: def(D) thin -> List[D],
) -> List[Quad[A, B, C, D]]:
    var out = List[Quad[A, B, C, D]]()
    var a_c = a_shrink(t.first)
    for i in range(len(a_c)):
        out.append(Quad[A, B, C, D](a_c[i].copy(), t.second.copy(), t.third.copy(), t.fourth.copy()))
    var b_c = b_shrink(t.second)
    for i in range(len(b_c)):
        out.append(Quad[A, B, C, D](t.first.copy(), b_c[i].copy(), t.third.copy(), t.fourth.copy()))
    var c_c = c_shrink(t.third)
    for i in range(len(c_c)):
        out.append(Quad[A, B, C, D](t.first.copy(), t.second.copy(), c_c[i].copy(), t.fourth.copy()))
    var d_c = d_shrink(t.fourth)
    for i in range(len(d_c)):
        out.append(Quad[A, B, C, D](t.first.copy(), t.second.copy(), t.third.copy(), d_c[i].copy()))
    return out^


def no_shrink[T: Value](x: T) -> List[T]:
    return List[T]()


# -------------------------------------------------------------------
# Shrinking driver: repeats the first candidate that still falsifies, until
# none does or the budget is spent. A candidate the predicate discards with
# assume() does not count. The run's own bookkeeping is restored each time.
# -------------------------------------------------------------------

def shrink_input[T: Value](
    var input: T,
    mut r: Run,
    pred: def(T, mut Run) thin -> Bool,
    shrinker: def(T) thin -> List[T],
    mut iterations: Int,
    budget: Int = 128,
) -> T:
    iterations = 0
    for _ in range(budget):
        var candidates = shrinker(input)
        var improved = False
        for k in range(len(candidates)):
            var saved = r.ctx.copy()
            r.ctx = Ctx()
            var held = pred(candidates[k], r)
            var v = r.ctx.verdict
            r.ctx = saved^
            if v == Verdict.SKIP:
                continue
            if not held:
                input = candidates[k].copy()
                improved = True
                iterations += 1
                break
        if not improved:
            break
    return input^


# -------------------------------------------------------------------
# Messages and seeds.
# -------------------------------------------------------------------

def hex_u64(v: UInt64) -> String:
    if v == 0:
        return "0"
    var digits = "0123456789abcdef".as_bytes()
    var rev = List[Int]()
    var x = v
    while x != 0:
        rev.append(Int(x & 15))
        x >>= 4
    var out = String()
    for i in range(len(rev) - 1, -1, -1):
        out += chr(Int(digits[rev[i]]))
    return out^


def format_found(
    query: String,
    lvl: Level,
    trial_idx: Int,
    shown: String,
    shrink_iters: Int,
    seed: UInt64,
) -> String:
    var o = query + " falsified at level " + String(lvl.idx) + " trial " + String(trial_idx)
    o += " (walk_steps=" + String(lvl.walk_steps) + " fin_bound=" + String(lvl.fin_bound) + ")"
    if shrink_iters > 0:
        o += "; shrunk " + String(shrink_iters) + " step(s)"
    if shown.byte_length() > 0:
        o += "; minimum=" + shown
    o += "; re-run with property_seed=0x" + hex_u64(seed)
    return o^


def format_provably_none(query: String, seed: UInt64, ctx: Ctx) -> String:
    var o = query + " held across the ladder; seed=0x" + hex_u64(seed)
    var total = ctx.trials_counted
    if len(ctx.class_order) > 0 and total > 0:
        o += "; classifications:"
        var first = True
        for label in ctx.class_order:
            if not first:
                o += ","
            first = False
            var n = ctx.class_hits.get(label).value()
            var pct = (100 * n + total // 2) // total
            o += " " + label + " " + String(pct) + "% (" + String(n) + "/" + String(total) + ")"
    return o^


# 0x-prefixed hex or plain decimal; 0 on anything else.
def parse_seed(s: String) -> UInt64:
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        return 0
    var base = UInt64(10)
    var i = 0
    if n > 2 and b[0] == 48 and (b[1] == 120 or b[1] == 88):
        base = 16
        i = 2
    var acc = UInt64(0)
    while i < n:
        var c = Int(b[i])
        var d = -1
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        if d < 0 or UInt64(d) >= base:
            return 0
        acc = acc * base + UInt64(d)
        i += 1
    return acc


# A caller seed wins; else PROPERTY_SEED; else the clock.
def pick_seed(caller_seed: UInt64) -> UInt64:
    if caller_seed != 0:
        return caller_seed
    var parsed = parse_seed(getenv("PROPERTY_SEED"))
    if parsed != 0:
        return parsed
    var s = UInt64(perf_counter_ns()) * 0x9E3779B97F4A7C15
    return s if s != 0 else 0xC0FFEE


def run_predicate[T: Value](
    pred: def(T, mut Run) thin -> Bool, input: T, mut r: Run
) -> Verdict:
    if r.ctx.verdict == Verdict.SKIP:
        return Verdict.SKIP
    r.ctx.verdict = Verdict.HOLD
    var held = pred(input, r)
    if r.ctx.verdict == Verdict.SKIP:
        return Verdict.SKIP
    r.ctx.verdict = Verdict.HOLD if held else Verdict.FALSIFY
    return r.ctx.verdict


# -------------------------------------------------------------------
# Resolvers.
# -------------------------------------------------------------------

def resolve_with_ladder[T: Value](
    query: String,
    ladder: List[Level],
    make_input: def(mut Run, Level) thin -> T,
    pred: def(T, mut Run) thin -> Bool,
    shrinker: def(T) thin -> List[T],
    show: def(T) thin -> String,
    seed: UInt64 = 0,
) -> Trial:
    var actual = pick_seed(seed)
    var r = Run(actual)
    var last_idx = 0
    for li in range(len(ladder)):
        ref lvl = ladder[li]
        last_idx = lvl.idx
        var trial_counter = 0
        var assumed_skipped = 0
        var assume_cap = lvl.num_inst * 10
        while trial_counter < lvl.num_inst:
            if assumed_skipped >= assume_cap:
                break
            r.ctx.verdict = Verdict.HOLD
            var input = make_input(r, lvl)
            var v = run_predicate[T](pred, input, r)
            if v == Verdict.SKIP:
                assumed_skipped += 1
                continue
            if v == Verdict.FALSIFY:
                var iters = 0
                var minimum = shrink_input[T](input^, r, pred, shrinker, iters)
                return Trial(
                    Outcome.FOUND,
                    lvl.idx,
                    trial_counter,
                    format_found(query, lvl, trial_counter, show(minimum), iters, actual),
                )
            r.ctx.trials_counted += 1
            trial_counter += 1
    return Trial(
        Outcome.PROVABLY_NONE, last_idx, 0, format_provably_none(query, actual, r.ctx)
    )


def resolve[T: Value](
    query: String,
    make_input: def(mut Run, Level) thin -> T,
    pred: def(T, mut Run) thin -> Bool,
    shrinker: def(T) thin -> List[T],
    show: def(T) thin -> String,
    seed: UInt64 = 0,
) -> Trial:
    return resolve_with_ladder[T](
        query, default_ladder(), make_input, pred, shrinker, show, seed
    )


def _no_show[T: Value](x: T) -> String:
    return String()


# No shrinker and no printer.
def resolve_plain[T: Value](
    query: String,
    make_input: def(mut Run, Level) thin -> T,
    pred: def(T, mut Run) thin -> Bool,
    seed: UInt64 = 0,
) -> Trial:
    return resolve[T](query, make_input, pred, no_shrink[T], _no_show[T], seed)
