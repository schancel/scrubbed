/// The single exception type the reader side of this package throws for
/// malformed, truncated, or unsupported input.
///
/// Reader code checks every length, offset, count, and index it takes from
/// the file explicitly and reports violations with this exception; it does
/// not rely on D array bounds checks (which `-release` builds disable) to
/// catch hostile input.
module parquet.exception;

/// Thrown for input that is not valid Parquet, is truncated, or uses a
/// feature this package does not implement (the message says which).
class ParquetFormatException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__,
            Throwable next = null) @safe pure nothrow {
        super(msg, file, line, next);
    }
}

/// `enforce`-style check that throws `ParquetFormatException`.
void check(bool condition, lazy string msg, string file = __FILE__,
        size_t line = __LINE__) {
    if (!condition) throw new ParquetFormatException(msg, file, line);
}
