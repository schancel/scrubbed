/// Failure identity for invalid (non-UTF-8) input encoding, independent of
/// which module detected it or which exception type wraps it.
///
/// Deliberately has no dependency beyond `object.d`: several call sites that
/// need `InvalidEncodingFailure` (and the domain modules that throw it) are
/// also built standalone by the experiments/ release-gate check programs
/// (see docs/pii-patterns.md, docs/pii-policy.md), and this module must not
/// drag in `domain.failure`'s own dependency on `domain.document` (needed
/// there only for `FailureRecord`'s `DocumentId` field, which is unrelated
/// to encoding-failure identification) just to name that interface.
module domain.encoding_failure;

/// Marker for a failure that stems from invalid (non-UTF-8) input encoding,
/// independent of which module detected it or which exception type wraps
/// it. `text-transform`'s `fix-mojibake` filter surfaces this directly as
/// `std.utf.UTFException`, but several other stages/domain modules
/// independently re-validate UTF-8 ahead of that filter and rewrap the
/// failure into their own exception type. A caller that needs to recognize
/// "this failure is invalid UTF-8 input" regardless of stage order or
/// wrapper type -- e.g. cli.d's per-document quarantine classification --
/// matches this interface in addition to `UTFException` rather than
/// hard-coding every domain module's own exception type.
interface InvalidEncodingFailure {}

/// A ready-made exception for a call site that independently detects
/// invalid UTF-8 and wants that failure recognized via
/// `InvalidEncodingFailure` without adopting a different exception type
/// for its other, unrelated failure reasons.
class InvalidUtf8Exception : Exception, InvalidEncodingFailure {
    this(string message) { super(message); }
}
