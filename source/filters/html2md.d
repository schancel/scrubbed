/// STUB, not wired into the registry yet -- deliberately, so
/// `pipeline.availableFilters()` never lies about what's actually
/// implemented. An HTML->Markdown converter is a genuinely more tractable
/// target than full trafilatura-style main-content/boilerplate-removal
/// extraction (no need to guess "is this a nav bar or real content," just
/// a mechanical tag->markdown mapping), but it still needs a real HTML
/// parser underneath, not regex tag-stripping -- regex-based HTML
/// handling breaks on nested/malformed markup in ways that silently
/// corrupt output rather than failing loudly.
///
/// TODO (see TODO.md phase 4):
///   1. Pick or write a D HTML/XML parser (check the D package registry,
///      code.dlang.org, for an existing one before writing one -- e.g.
///      search "html" / "xml" on code.dlang.org; don't assume none
///      exists without checking).
///   2. Walk the resulting DOM, mapping common tags to markdown:
///      h1-h6 -> #...######, p -> paragraph break, a[href] -> [text](url),
///      strong/b -> **x**, em/i -> *x*, ul/li -> "- x", ol/li -> "1. x",
///      code/pre -> `x`/fenced blocks, blockquote -> "> x", img[alt,src]
///      -> ![alt](src), table -> markdown table (the fiddliest one --
///      consider deferring/flattening to plain text if not worth the
///      complexity).
///   3. Decide what to do with script/style/nav/footer/aside tags --
///      dropping them entirely is reasonable for a markdown-conversion
///      tool (distinct from trafilatura's harder "which of the remaining
///      content is boilerplate" problem).
///   4. Register it: `registerFilter("html2md", &htmlToMarkdown);`
module filters.html2md;
