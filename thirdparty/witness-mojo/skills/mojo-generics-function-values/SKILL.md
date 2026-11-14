---
name: mojo-generics-function-values
description: Use when Mojo generics or function values fail to compile.
version: 1.0.0
author: K. S. Ernest (iFire) Lee
license: MIT
metadata:
  hermes:
    tags: [mojo, generics, function-types, collections]
    related_skills: [contract-witness-mojo, mojo-port-with-parity-tests, mojo-syntax]
---

# Mojo generics and function values (Mojo 1.1.0)

## When to Use

- A Mojo build says "cannot implicitly convert X to X", "rebind input type" or "lacking evidence".
- A function is stored in a `List`, passed as a parameter, or returned from another function.
- Porting C++ code that leans on closures, `std::function`, `std::set` or `std::map`.

Lessons from porting C++ closure-based code to Mojo. Run with the mojoler venv: `~/5-repository/zone-relay-mojo-work/mojoler/.venv/bin`.

- **Function types in containers or returns:** a spelled-out `def(mut Run, Level) thin -> T` stored in `List[...]` or returned from a function fails with "cannot implicitly convert X to X" or a `rebind` pass error. Define `comptime Gen[T: Value] = def(mut Run, Level) thin -> T` and use `List[Gen[T]]` and `-> Gen[Out]` everywhere, tests included.
- **`fn` is a keyword:** a parameter named `fn` gives "expected argument name". Use `f`.
- **Set is not in the prelude:** `from std.collections import Set` in every file that names it. `from pkg import *` does not re-export it.
- **Constraints for collections:** `Set.add` and `Dict.__setitem__` need Deinitable. Write `T: KeyElement & Value` where `comptime Value = Copyable & Deinitable`, or generic bodies fail with "lacking evidence".
- **`Dict[k]` raises:** inside a non-raising def, iterate `for item in d.items()` and read `item.key` / `item.value` instead of indexing.
- **Generic bodies are checked lazily:** a clean build of the library is not proof. Instantiate every generic from a test before trusting it.
- **Shell:** macOS `sed -i` rejects multi-line patterns here; do multi-line edits with python3 or the patch tool.
- **Language-level:** no closures, so a C++ `Generator<T>` that captured arguments becomes a function that takes those arguments and the Run, or a one-line wrapper def.
