/// Narrow declarations for the pinned, statically linked SQLite amalgamation.
module effects.sqlite_ffi;

extern(C) {
    struct sqlite3;
    struct sqlite3_stmt;
    int sqlite3_open_v2(const(char)*, sqlite3**, int, const(char)*);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const(char)*, void*, void*, char**);
    int sqlite3_busy_timeout(sqlite3*, int);
    const(char)* sqlite3_errmsg(sqlite3*);
    const(char)* sqlite3_libversion();
    int sqlite3_prepare_v2(sqlite3*, const(char)*, int, sqlite3_stmt**, const(char)**);
    int sqlite3_finalize(sqlite3_stmt*);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_bind_text(sqlite3_stmt*, int, const(char)*, int, void*);
    int sqlite3_bind_blob(sqlite3_stmt*, int, const(void)*, int, void*);
    int sqlite3_bind_int64(sqlite3_stmt*, int, long);
    int sqlite3_column_int(sqlite3_stmt*, int);
    long sqlite3_column_int64(sqlite3_stmt*, int);
    const(char)* sqlite3_column_text(sqlite3_stmt*, int);
    const(void)* sqlite3_column_blob(sqlite3_stmt*, int);
    int sqlite3_column_bytes(sqlite3_stmt*, int);
    int sqlite3_column_type(sqlite3_stmt*, int);
    int sqlite3_changes(sqlite3*);
    int sqlite3_wal_checkpoint_v2(sqlite3*, const(char)*, int, int*, int*);
}

enum SQLITE_OK = 0;
enum SQLITE_ROW = 100;
enum SQLITE_DONE = 101;
enum SQLITE_NULL = 5;
enum SQLITE_OPEN_READWRITE = 2;
enum SQLITE_OPEN_CREATE = 4;
enum SQLITE_CHECKPOINT_TRUNCATE = 3;
