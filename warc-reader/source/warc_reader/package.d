/// warc-reader: a minimal, zero-dependency, pure-D incremental reader for
/// **uncompressed** WARC/1.1 record streams.
///
/// `import warc_reader;` re-exports the small public surface: `WarcReader`,
/// `WarcRecord`, `WarcField`, `WarcError`, `WarcVisit`, and the fixed
/// per-record size limits. See this package's README for scope, and
/// `warc_reader.reader` for the implementation.
module warc_reader;

public import warc_reader.reader;
