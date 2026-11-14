# SPDX-License-Identifier: MIT
# The Mojo counterpart of witness-cpp's doctest bindings (PROP_CHECK,
# PROP_CHECK_SHRINK, PROP_CHECK_SEED). Each runs the ladder and raises an Error
# carrying the trial message, with its seed, when a property is falsified; a
# test runner such as `mojo test` or a `main() raises` reports it.

from witness.ladder import *


def _require_held(trial: Trial) raises:
    if trial.outcome == Outcome.FOUND:
        raise Error(trial.message)


# PROP_CHECK: no shrinker, no printer.
def prop_check[T: Value](
    query: String,
    make_input: def(mut Run, Level) thin -> T,
    pred: def(T, mut Run) thin -> Bool,
) raises:
    _require_held(resolve_plain[T](query, make_input, pred))


# PROP_CHECK_SHRINK: a failing input is shrunk and shown.
def prop_check_shrink[T: Value](
    query: String,
    make_input: def(mut Run, Level) thin -> T,
    pred: def(T, mut Run) thin -> Bool,
    shrinker: def(T) thin -> List[T],
    show: def(T) thin -> String,
) raises:
    _require_held(resolve[T](query, make_input, pred, shrinker, show))


# PROP_CHECK_SEED: a fixed seed, so the run repeats.
def prop_check_seed[T: Value](
    query: String,
    make_input: def(mut Run, Level) thin -> T,
    pred: def(T, mut Run) thin -> Bool,
    seed: UInt64,
) raises:
    _require_held(resolve_plain[T](query, make_input, pred, seed))
