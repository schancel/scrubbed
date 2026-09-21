# Pinned SQLite amalgamation

`sqlite3.c` and `sqlite3.h` are unmodified upstream SQLite 3.53.4 amalgamation
files from `https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip`.
The archive SHA3-256 published by SQLite and checked before extraction was
`628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`.
For independent byte comparison, the extracted files' SHA-256 values are:

- `sqlite3.c`: `b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189`
- `sqlite3.h`: `919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d`

The build compiles `sqlite3.c` with `SQLITE_THREADSAFE=1` and
`SQLITE_OMIT_LOAD_EXTENSION`, then links its object into the executable. The
object file is generated and ignored; no system `libsqlite3` is needed. SQLite
core code is [public domain](https://www.sqlite.org/copyright.html), with
notice recorded in `THIRD_PARTY_NOTICES.md`.
