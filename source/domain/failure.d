/// Failure identity and severity at the file-processing boundary.
module domain.failure;

import domain.document : DocumentId;

enum FailurePhase { read, decode, filter, sink, manifest, policy, scheduler, log }
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
