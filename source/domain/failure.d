/// Failure identity and severity at the file-processing boundary.
module domain.failure;

import domain.document : DocumentId;

enum FailurePhase { read, decode, filter, sink, manifest, policy, resource, scheduler, log }
enum FailureClass { document, fatal }

struct FailureRecord {
    DocumentId documentId;
    string sinkKey;
    FailurePhase phase;
    FailureClass classification;
    bool sinkTouched;
    /// Prior terminal, durably acknowledged manifest decisions, including failures.
    size_t completedPrefix;
    string reason;
    Exception cause;
}

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
