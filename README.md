# fabric-store

SQLite runs in a native process with a custom VFS with no local file. The pages live in FoundationDB, so a handoff copies nothing: another machine opens the
same database and reads pages.

## Licence

Licensed under either of

* Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
* MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.
