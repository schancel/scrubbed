# Adding a filter

Each implemented module here owns its transform, registration, and nearby
`unittest` block. [`normalize.d`](normalize.d) is a concrete plain-filter
example: `normalizeLineEndingsFilter(string)` materializes its lazy range,
then `static this()` registers it as `normalize-line-endings` with
`registerFilter`. The registered signature is `string function(string)`;
the pipeline applies stages in the user's specified order.

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

For options, use [`mojibake.d`](mojibake.d) as the existing example:
`registerFilterFactory("fix-mojibake", &configureMojibake)` registers a
factory that validates `FilterOptions` and returns a configured
`ConfiguredFilter`; `Pipeline.buildConfigured` calls it once per chain
construction. A plain filter rejects nonempty options. [`entities.d`](entities.d)
decodes a limited set of HTML entities and uses `mojibake`'s CP1252 helper;
[`punctuation.d`](punctuation.d) owns quote normalization.

[`html2md.d`](html2md.d) is a stub, deliberately unregistered and not a
working HTML-to-Markdown filter. It is not an extension API.
