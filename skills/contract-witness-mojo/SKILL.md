---
name: contract-witness-mojo
description: Use when adding property tests to contract-witness-mojo.
version: 1.0.0
author: K. S. Ernest (iFire) Lee
license: MIT
metadata:
  hermes:
    tags: [mojo, property-testing, shrinking, witness]
    related_skills: [mojo-generics-function-values, mojo-port-with-parity-tests, write-checks-that-can-fail]
---

# contract-witness-mojo

## When to Use

- Adding or changing a generator, shrinker or combinator in V-Sekai-fire/contract-witness-mojo.
- Writing a property test against the ladder, in this repo or in one that vendors it.
- Porting another witness-cpp feature to Mojo.

Repo: V-Sekai-fire/contract-witness-mojo (local: ~/5-repository/zone-relay-mojo-work/contract-witness-mojo). A property-testing ladder: three rungs (200, 800, 2000 trials), shrinking, and a seed in every FOUND message. Ported from witness-cpp (sibling dir), which follows Lean plausible-witness-dag.

## Build and run

    export PATH=~/5-repository/zone-relay-mojo-work/mojoler/.venv/bin:$PATH
    mojo build -I src tests/test_witness.mojo -o $TMPDIR/t && $TMPDIR/t
    mojo build -I src tests/test_extended.mojo -o $TMPDIR/t && $TMPDIR/t

Both must end in `ALL PASS`. Build to $TMPDIR, not the repo.

## Shape of the API

- Generator: `def(mut Run, Level) thin -> T`; alias `Gen[T]`. Predicate: `def(T, mut Run) thin -> Bool`. Shrinker: `def(T) thin -> List[T]`.
- `resolve[T](query, gen, pred, shrinker, show, seed)`; `resolve_plain` has no shrinker or printer. `Trial.outcome` is FOUND or PROVABLY_NONE.
- `witness.check`: `prop_check`, `prop_check_shrink`, `prop_check_seed` raise Error(message) on FOUND.
- Combinators draw at once (no closures): `gen_transform(r, lvl, gen, f)`, `gen_bind(r, lvl, gen, f)` with `f -> Gen[Out]`, `gen_oneof(r, lvl, List[Gen[T]])`.
- Containers: list, array, optional, pair, triple, quad, set (Set), map (Dict). Set/Dict keep insertion order and need hashable keys.

## Rules when adding a feature

1. Write a planted-false control for every property: the same generator with a hostile predicate must be FOUND. A property test that cannot fail proves nothing.
2. Fix a seed in tests (`0x..`) so a failure repeats; the RNG is SplitMix64, so seeds do not match C++ runs.
3. Shrunk minima are not exact: halving stops anywhere (a falsifying `n >= 10` shrinks to 10..19). Assert a prefix or range, never one value.
4. Draw order must be fixed (a then b then c) so RNG use is stable.
5. Update README's ported/reshaped list and both build commands.
