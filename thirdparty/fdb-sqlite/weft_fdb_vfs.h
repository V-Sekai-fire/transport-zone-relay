// The entry points of the FoundationDB VFS (fdb_vfs.c), for a program that links it.
//
// Programs used to redeclare these by hand, so a changed signature broke each of them
// at link or run time instead of at compile time. Include this instead.
//
// SPDX-License-Identifier: Apache-2.0
#ifndef WEFT_FDB_VFS_H
#define WEFT_FDB_VFS_H

#ifdef __cplusplus
extern "C" {
#endif

// Start the FoundationDB client once for the process. `cluster_file` may be NULL for the
// default. Returns 0, or a FoundationDB error code. Registers `weft_fdb_stop` with atexit.
int weft_fdb_start(const char *cluster_file);

// Stop the client. Idempotent.
void weft_fdb_stop(void);

// Register the "weft_fdb" VFS with SQLite. Returns SQLITE_OK (0) or an SQLite error.
int weft_vfs_register(int make_default);

#ifdef __cplusplus
}
#endif

#endif
