# Selected-field JSONL stdin/stdout

The end-user mode is explicit on `run` (or `repair`):

```sh
scrubbed run --input - --output - --jsonl-fields text,title \
  --dataset-namespace corpus --source-key logical-source-001 \
  --max-jsonl-line-bytes 1048576 --max-jsonl-output-bytes 2097152
```

All five JSONL options and both `-` endpoints are required. Field names are
unique top-level JSON keys. `--filters` or `--config` uses the same resolved
filter chain as file processing. File scheduling options, `--list-filters`,
and `--explain` are unavailable in this mode. `--validate` checks options,
identity, config, and filters without reading stdin or writing stdout.
`--dry-run` processes records and reports the bounded count to stderr but
writes no stdout. Normal stdout contains only JSONL records; status and
errors are on stderr. Help and argument errors exit before streaming starts.

A record's ID is derived from the caller namespace, source key, and 1-based
physical line ordinal; it does not depend on the transport path. Retry with
the same key and line positions for stable IDs. Record order and untouched
parsed JSON values are preserved; object key order, escape spelling,
whitespace, and formatting are not byte-preserved. Malformed JSON and invalid
selected text have distinct error categories. Processing stops on the first
failed record (exit 1), reporting its line, DocumentId, and number of fully
flushed prior records. A broken stdout writer may have emitted part of the
current record; the current record is never reported as completed. There is
no atomic rollback or quarantine. Invalid invocation/config exits 2.

The stream is synchronous: no subsequent read callback occurs while stdout
blocks on a record. On POSIX stdin, one read returns available bytes rather
than waiting for 4096 bytes or EOF, so a complete line can be emitted while
the producer keeps stdin open. The fixed 4096-byte input chunk can read up to
4095 bytes past the current line's LF before that write; it does not form a
record queue. On POSIX, CLI JSONL mode ignores SIGPIPE for the remaining
process lifetime so a closed consumer produces a writer diagnostic.
The caller must impose a text-transform resource policy separately, because
an opaque filter callback can allocate beyond the adapter's byte caps.

## Adapter boundary

`effects.jsonl_stream.processJsonl` accepts byte-reader and byte-writer
delegates, a required stable dataset namespace and source key, selected
top-level field names, a text-transform delegate, and positive byte caps.
`effects.stdio_stream` binds the same operation to caller-owned `File` handles
or process stdin/stdout. The CLI delegates to this adapter and shares the
existing filter-chain builder; it does not introduce a second JSONL parser.

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
The `File` binding flushes each record before processing the next. The reader
fetches chunks of at most 4096 bytes, so it may already have read up to 4095
bytes beyond the current record's LF when writing starts. It performs no
further read callback or record processing while the writer blocks; there is
no unbounded record queue. Earlier completed records stay written on failure.
A writer fault reports `partialOutputPossible = true` for the current
record, because stdout and general streams have no atomic rollback.

Run the release-active harness with:

```sh
ldc2 -O -release -enable-inlining -i -I=source experiments/jsonl_stream/check.d -of=/tmp/issue16-check
/tmp/issue16-check
ldc2 -O -release experiments/jsonl_stream/cli_check.d -of=/tmp/issue16-cli-check
/tmp/issue16-cli-check ./scrubbed
```
