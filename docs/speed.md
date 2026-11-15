# Why it was slow, and the two things that made it faster

## The profile

The four-world gate was sampled for 10 seconds with macOS's `sample`. 92% of the samples of its
one busy thread were inside the editor, all of them in the two neighbouring stretches of code that
are the sandbox's RISC-V interpreter. Every other thread was waiting. The work was MuJoCo's
forward pass for a body of 700 muscles, about 10 ms a body a tick, done for four bodies one after
another on one core: 41 ms for a tick that is 15.6 ms long. The codec, the router, the observers
and the curves together were 3% of a tick. Starting the editor took half a second.

## Four threads

Each person has a physics guest of its own, and the four are stepped on the engine's worker
pool. Nothing is shared between them, so the results are the same to every printed digit.

## Binary translation

The sandbox can run a guest from a native library made from the guest's own code, in place of
interpreting it. This editor has that tier and no JIT. The library is made ahead of time:

1. Set the project settings `sandbox/binary_translation/enabled` to true and
   `sandbox/binary_translation/cache_dir` to a directory.
2. Load the guest once with `GODOT_SANDBOX_BINTR_EMIT` set to that directory and
   `GODOT_SANDBOX_BINTR_UNITS` to 8. The sandbox writes `bintr-<HASH>.<i>.c`, 63 MB for the
   physics guest.
3. Compile the units and link them as `bintr-<HASH>.dylib` in the same directory:
   `cc -O2 -fPIC -fno-strict-aliasing -w -c` each, then `cc -dynamiclib`. It took 23 seconds.
4. Load the guest again. `is_binary_translated()` answers true.

The gates do steps 1 and 4 themselves when `BINTR` names the directory, and print the tier.
The hash covers the guest and the host's layout, so each guest and each platform has its own
library, and a guest that changes needs a new one.

## What was measured

All on one macOS arm64 machine, the four-world gate of 960 ticks, 15 seconds of the clock.

| | Forward pass of one body | Physics, share of a tick a world | The whole gate |
| --- | --- | --- | --- |
| interpreted, one thread | 10.0 ms | 0.66 | 45.7 s |
| interpreted, four threads | 10.0 ms | 0.33 | 29.1 s |
| translated, four threads | 4.1 ms | 0.13 | 19.4 s |

The gate's own numbers did not move: 12 of 12 pairs, 1,896 of 1,896 verdicts, 0.484 mm mean and
34.034 mm largest on every row. The body placements of the translated guest have the same digest
as the interpreter's on the pose that was tried.

Four threads gave two times and not four, so something is shared after all, most likely memory
bandwidth; it was not looked into.

## Not done

The translated tier is not yet compared with the interpreter on every call and every host, which
is the parity rung. The inverse was not run on it. The single-body gates and the client program
do not take `BINTR` yet. A forward pass does far more than a played clip needs; a call that does
kinematics alone would be faster still and is a change to the physics guest.
