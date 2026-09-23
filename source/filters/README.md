# Adding a filter

Each implemented module here owns its transform, registration, and nearby
`unittest` block. [`normalize.d`](normalize.d) demonstrates both contracts:
its public compatibility functions return materialized strings, while
`static this()` uses `registerStreamingFilter` to register bounded scalar
push/finish callbacks. The pipeline fuses consecutive streaming registrations
in the user's specified order and materializes once at the end of the group.

For example, `--filters normalize-line-endings,strip-control` changes
`"a\r\n\0b"` to `"a\nb"`: the first stage normalizes CRLF and the second
removes NUL.

For another plain filter, follow the same seam:

```d
module filters.my_filter;
import pipeline : registerFilter;

string myFilter(string text) { /* transform text */ return text; }
static this() { registerFilter("my-filter", &myFilter); }
unittest { assert(myFilter("example") == "example"); }
```

Place the implementation and meaningful input/output tests in its own
`source/filters/my_filter.d`, then add `import filters.my_filter;` alongside
the filter imports in [`cli.d`](../cli.d). That import is required to link the
module and run its `static this()` registration; registration alone in an
unimported module is not sufficient. The filter can then be selected with
`--filters my-filter` or a JSON `filters` entry. No registry list or pipeline
switch needs editing. From the repository root, run `dub test`,
`dub build --build=release`, and `./scrubbed --list-filters` to check the
module tests, executable, and visible registration.

Use `registerStreamingFilter` instead when an algorithm can consume one
decoded scalar at a time with fixed state and emit at most
`maxStreamingExpansion` scalars per push/finish call. A module may retain a
separate public materialized helper for direct callers and equivalence tests;
it is not duplicated in the registry. Mutable state belongs in
`StreamingState`; do not retain input/output pointers. Runtime groups are
currently capped at 16 filters and decode UTF-8 strictly. Algorithms requiring
lookahead beyond fixed state, document-wide scoring, or unbounded expansion
remain plain filters and therefore explicit materialization barriers.

For options, use [`mojibake.d`](mojibake.d) as the existing example. Its
`registerTypedFilterFactory` declaration owns the `encodings:text` and
`max-passes:integer` schema; `Pipeline.buildTyped` validates names and exact
scalar types before calling the factory once per chain construction. During
the v1 compatibility window, the same registration retains the predecessor
string factory so current JSON coercion and diagnostics do not change. New
configurable filters should expose a typed factory whose result is a plain
function pointer plus transitive-immutable parsed configuration; configured
delegates and mutable retained state are rejected at this boundary. A plain filter rejects
nonempty options. [`entities.d`](entities.d)
decodes a limited set of HTML entities and uses `mojibake`'s CP1252 helper;
[`punctuation.d`](punctuation.d) owns quote normalization.

`fix-mojibake` first scores the existing whole-string Latin-1/CP1252 round
trip. If that cannot improve the input because surrounding codepoints are
unmappable in the enabled legacy encoding(s), it scans UTF-8 codepoints for exact
legacy-byte sequences (two to four bytes) and considers short adjacent runs.
It accepts a single-sequence edit only when plausibility strictly improves;
an adjacent run requires exact second-pass improvement. The configured
`max-passes` still bounds the number of actual edits. A standalone `Â`/C2
sequence is intentionally ambiguous and is left alone in mixed text; invalid
or incomplete sequences also abstain. Boundaries are codepoint offsets, and
every unmatched byte slice is copied verbatim. This is not charset guessing.
`normalize-line-endings`, `uncurl-quotes`, and `strip-control` operate in the
user's chosen order; none supplies evidence that a span is mojibake.

[`html2md.d`](html2md.d) is a stub, deliberately unregistered and not a
working HTML-to-Markdown filter. It is not an extension API.
