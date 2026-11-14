# contract-witness-mojo

A property-testing ladder for Mojo, ported from [contract-witness-cpp](https://github.com/V-Sekai-fire/contract-witness-cpp), which follows the Lean `plausible-witness-dag` library.

A property is checked against generated inputs over three rungs of growing budget (200, 800 and 2,000 trials). A failing input is shrunk, and the message names the seed that reproduces it.

## Use

```mojo
from witness.ladder import *

def gen_ints(mut r: Run, lvl: Level) -> List[Int]:
    return gen_list[Int](r, lvl, gen_int)

def short(v: List[Int], mut r: Run) -> Bool:
    return len(v) <= 100

def main():
    var t = resolve[List[Int]]("short", gen_ints, short, shrink_list[Int], show_ints)
    print(t.message)   # falsified at level 2 ...; minimum=[...]; re-run with property_seed=0x...
```

`t.outcome` is `Outcome.FOUND` or `Outcome.PROVABLY_NONE`. `PROPERTY_SEED=<n or 0xhex>` or an explicit seed makes a run repeat.

    mojo build -I src tests/test_witness.mojo -o t && ./t
 mojo build -I src tests/test_extended.mojo -o t && ./t

## What differs from the C++

- No closures. A generator is `def(mut Run, Level) thin -> T` and a predicate is `def(T, mut Run) thin -> Bool`. A generator that needs a bound is a one-line function of its own.
- `Run` carries the RNG and what `assume`, `classify` and `collect` record, so there is no global state.
- The RNG is SplitMix64, not `mt19937_64`. A seed repeats a run in Mojo; it does not repeat a C++ run.
- Ported, all of it: the ladder; generators for bool, char, int, uint, int64, uint64, float64, string, `gen_string_of`, list, array, optional, pair, `gen_triple`, `gen_quad`, set, map, `gen_element`, `gen_frequency`, `gen_oneof` and `gen_filter`; shrinkers for the same types; `assume`, `classify`, `collect`; seed selection and the message formats.
- Reshaped, because Mojo has no closures:
  - `gen_transform(r, lvl, gen, f)` and `gen_bind(r, lvl, gen, f)` draw a value at once instead of returning a new generator. `f` is `def(In) thin -> Out` for transform and `def(In) thin -> Gen[Out]` for bind. A function that calls two generators does the same job.
  - `gen_oneof(r, lvl, gens)` takes a `List[Gen[T]]`. `Gen[T]` is an alias for `def(mut Run, Level) thin -> T`; use it, not the spelled-out type, when a generator sits in a container or is returned.
  - Sets and maps are Mojo `Set` and `Dict`, so keys must be hashable. They keep insertion order, where the C++ `std::set` and `std::map` sort. `shrink_set` and `shrink_map` drop one entry at a time and leave values alone, as the C++ does.
  - Tuples come as `Pair`, `Triple` and `Quad` with `gen_` and `shrink_` functions. Draws and shrinks go slot by slot, left to right.
  - The doctest macros become `prop_check`, `prop_check_shrink` and `prop_check_seed` in `witness.check`. Each raises an `Error` holding the trial message, seed included, when a property is falsified.
- `gen_int` and `gen_uint` give Mojo `Int` (64 bits); `gen_int64` and `gen_uint64` give `Int64` and `UInt64`.

## Skills

`skills/` holds two agent skills: how to add property tests to this repo, and the Mojo generics and function-value traps met while porting.

## Licence

MIT, the licence of the C++ original.
