/// Acknowledged failure recording. Concrete error-file formats belong elsewhere.
module effects.failure_policy;

import domain.failure : FailureRecord;
import effects.local_manifest : LocalManifest, SinkKey, SinkState;

alias FailureAcknowledgment = void delegate(in FailureRecord);

/// The default port is manifest-backed: an exact, durable state read is the
/// acknowledgement. Callers may inject a separate durable logger later.
void recordDocumentFailure(LocalManifest manifest, SinkKey key,
        in FailureRecord failure, FailureAcknowledgment acknowledge = null) {
    if (failure.sinkTouched) manifest.markUncertain(key);
    else manifest.markFailed(key);
    auto row = manifest.lookup(key);
    auto expected = failure.sinkTouched ? SinkState.uncertain : SinkState.failed;
    if (row.isNull || row.get.state != expected ||
        row.get.key.document.text != failure.documentId.text ||
        row.get.key.sink != failure.sinkKey)
        throw new Exception("failure state was not durably acknowledged");
    if (acknowledge !is null) acknowledge(failure);
}
