# Standalone JSONL stream adapter

`effects.jsonl_stream.processJsonl` accepts byte-reader and byte-writer
delegates, a required stable dataset namespace and source key, selected
top-level field names, a text-transform delegate, and positive byte caps.
`effects.stdio_stream` binds the same operation to caller-owned `File` handles
or process stdin/stdout. This is an effects API, not CLI integration; no CLI
flag or end-user stdin/stdout mode is supplied here.

Each physical line is one object. LF and CRLF are accepted, as is a final
record without a newline. Empty lines are malformed records. The source
locator uses the namespace, caller-supplied source key, and 1-based physical
line ordinal (decimal string). Neither an output name nor a transport path
enters the ID. A retry with the same source key and lines gives the same IDs.
Selected fields must be JSON strings when present; absent fields are left
untouched. The delegate sees the selected field name, decoded string, and
`DocumentId`. All other fields retain their parsed JSON semantic values,
including nested arrays/objects, booleans, null, and supported integers.
Spelling, whitespace, escape style, and key order are not preserved.

To avoid silent value collapse in `std.json`, the adapter rejects duplicate
decoded object keys at every depth, decimal/exponent numbers, integers outside
the signed/unsigned 64-bit range, non-object records, and nesting deeper than
64. Decimal/exponent numbers are intentionally unsupported even when a
particular value could be represented by binary floating point. These are
`malformedJson` failures; a valid object whose selected field is not text or
whose text transform throws is `invalidText` instead. A failing record stops
processing; no quarantine policy is implied.

The reader holds one bounded line, and the writer is called synchronously
with one completed output record. `rawLineBytes` excludes the LF and one
terminal CR; `outputRecordBytes` includes the emitted LF. The raw cap bounds
parser-owned values, and each transformed string is checked against the
output cap before serialization. Serialization appends each JSON value only
while bytes remain under the output cap; no complete oversized output record
is built. A transform that internally allocates excessive memory is a
caller concern; the adapter cannot bound memory inside an opaque callback.
The `File` binding flushes each record before reading the next. No records
are queued while a writer blocks. Earlier completed records stay written on
failure. A writer fault reports `partialOutputPossible = true` for the current
record, because stdout and general streams have no atomic rollback.

Run the release-active harness with:

```sh
ldc2 -O -release -enable-inlining -i -I=source experiments/jsonl_stream/check.d -of=/tmp/issue16-check
/tmp/issue16-check
```
