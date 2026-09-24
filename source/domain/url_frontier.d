/// Pure, deterministic URL-frontier transitions for a later durable single writer.
module domain.url_frontier;

import std.algorithm.sorting : sort;

enum CandidateState : ubyte {
    queued,
    deferred,
    leased,
    completed,
    retryableFailed,
    permanentFailed,
}

enum AdmissionCode : ubyte {
    admittedQueued,
    admittedDeferred,
    duplicate,
    refusedSealed,
    refusedInvalidIdentity,
    refusedInvalidHost,
    refusedProvenanceLimit,
    refusedDepthLimit,
    refusedPageLimit,
    refusedHostLimit,
    refusedStoredByteLimit,
}

enum LeaseUnavailable : ubyte { none, canceled, activeLimit, noQueuedWork }
enum LeaseOutcome : ubyte { completed, retryableFailure, permanentFailure }
enum FinishCode : ubyte { applied, unknownCandidate, notLeased, staleGeneration }
enum ReclaimCode : ubyte { reclaimed, unknownCandidate, notLeased, staleGeneration }

struct FrontierLimits {
    size_t maxPages;
    size_t maxPagesPerHost;
    size_t maxDepth;
    size_t maxQueued;
    size_t maxActiveLeases;
    size_t maxStoredBytes;
    size_t maxProvenanceBytes;
}

/// The policy and canonical locator jointly form identity. All strings are opaque:
/// this module validates bounds but performs no URL parsing or normalization.
struct CandidateInput {
    string policyId;
    string canonicalLocator;
    string hostKey;
    size_t depth;
    string provenance;
}

struct CandidateKey {
    string policyId;
    string canonicalLocator;
}

struct Admission {
    AdmissionCode code;
    CandidateKey key;
}

struct LeaseToken {
    CandidateKey key;
    ulong generation;
}

struct LeaseAttempt {
    bool available;
    LeaseUnavailable unavailable;
    LeaseToken lease;
    CandidateInput candidate;
}

struct FinishResult {
    FinishCode code;
    Admission[] discoveries;
}

struct CandidateView {
    CandidateInput candidate;
    CandidateState state;
    ulong generation;
}

struct FrontierCounts {
    size_t pages;
    size_t queued;
    size_t deferred;
    size_t activeLeases;
    size_t completed;
    size_t retryableFailed;
    size_t permanentFailed;
    size_t storedBytes;
}

class FrontierException : Exception {
    this(string reason) { super("URL frontier: " ~ reason); }
}

private void require(bool okay, string reason) {
    if (!okay) throw new FrontierException(reason);
}

/// A single-writer transition model. Public calls are the intended transaction
/// boundaries; callers provide serialization when adapting it to persistence.
final class UrlFrontier {
private:
    struct Record {
        CandidateInput candidate;
        CandidateState state;
        ulong generation;
        bool deferredRetry;
    }

    FrontierLimits limits_;
    Record[] records;
    size_t[] ready;
    size_t[] deferred;
    size_t active_;
    size_t storedBytes_;
    bool sealed_;
    bool canceled_;

public:
    this(FrontierLimits limits) {
        require(limits.maxPages > 0, "page limit must be positive");
        require(limits.maxPagesPerHost > 0, "host limit must be positive");
        require(limits.maxQueued > 0, "queued limit must be positive");
        require(limits.maxActiveLeases > 0, "active lease limit must be positive");
        require(limits.maxStoredBytes > 0, "stored-byte limit must be positive");
        limits_ = limits;
    }

    FrontierLimits limits() const { return limits_; }
    bool isSealed() const { return sealed_; }
    bool isCanceled() const { return canceled_; }

    /// Completion is deliberately gated by sealing: an open empty frontier may
    /// still accept work. Failed retryable items remain scheduled until leased.
    bool isComplete() const {
        return sealed_ && ready.length == 0 && deferred.length == 0 && active_ == 0;
    }

    void seal() { sealed_ = true; }
    void cancelLeasing() { canceled_ = true; }
    void resumeLeasing() { canceled_ = false; }

    Admission admitSeed(CandidateInput candidate) {
        return admit(candidate);
    }

    LeaseAttempt takeLease() {
        LeaseAttempt result;
        if (canceled_) {
            result.unavailable = LeaseUnavailable.canceled;
            return result;
        }
        if (active_ >= limits_.maxActiveLeases) {
            result.unavailable = LeaseUnavailable.activeLimit;
            return result;
        }
        if (ready.length == 0) {
            result.unavailable = LeaseUnavailable.noQueuedWork;
            return result;
        }

        auto index = popFront(ready);
        auto record = &records[index];
        require(record.state == CandidateState.queued ||
            record.state == CandidateState.retryableFailed,
            "invalid ready state");
        require(record.generation != ulong.max, "lease generation exhausted");
        ++record.generation;
        record.state = CandidateState.leased;
        ++active_;
        promote();

        result.available = true;
        result.unavailable = LeaseUnavailable.none;
        result.lease = LeaseToken(keyOf(record.candidate), record.generation);
        result.candidate = copyInput(record.candidate);
        return result;
    }

    /// Applies the lease outcome and every discovery as one logical transition.
    /// Individual over-limit discoveries are finite typed refusals; they do not
    /// roll back the valid outcome or other discoveries.
    FinishResult finish(LeaseToken lease, LeaseOutcome outcome,
            const(CandidateInput)[] discoveries = null) {
        FinishResult result;
        auto found = find(lease.key);
        if (found == size_t.max) {
            result.code = FinishCode.unknownCandidate;
            return result;
        }
        auto record = &records[found];
        if (record.generation != lease.generation) {
            result.code = FinishCode.staleGeneration;
            return result;
        }
        if (record.state != CandidateState.leased) {
            result.code = FinishCode.notLeased;
            return result;
        }
        require(cast(uint)outcome <= cast(uint)LeaseOutcome.permanentFailure,
            "invalid lease outcome");

        --active_;
        final switch (outcome) {
        case LeaseOutcome.completed:
            record.state = CandidateState.completed;
            break;
        case LeaseOutcome.retryableFailure:
            enqueue(found, true);
            break;
        case LeaseOutcome.permanentFailure:
            record.state = CandidateState.permanentFailed;
            break;
        }
        foreach (discovery; discoveries) result.discoveries ~= admit(discovery);
        promote();
        result.code = FinishCode.applied;
        return result;
    }

    /// Invalidates the supplied generation before returning the item to pending
    /// work, so a late worker can never complete the reclaimed lease.
    ReclaimCode reclaim(LeaseToken lease) {
        auto found = find(lease.key);
        if (found == size_t.max) return ReclaimCode.unknownCandidate;
        auto record = &records[found];
        if (record.generation != lease.generation) return ReclaimCode.staleGeneration;
        if (record.state != CandidateState.leased) return ReclaimCode.notLeased;
        require(record.generation != ulong.max, "lease generation exhausted");
        ++record.generation;
        --active_;
        enqueue(found, false);
        promote();
        return ReclaimCode.reclaimed;
    }

    FrontierCounts counts() const {
        FrontierCounts result;
        result.pages = records.length;
        result.queued = ready.length;
        result.deferred = deferred.length;
        result.activeLeases = active_;
        result.storedBytes = storedBytes_;
        foreach (record; records) final switch (record.state) {
        case CandidateState.queued: break;
        case CandidateState.deferred: break;
        case CandidateState.leased: break;
        case CandidateState.completed: ++result.completed; break;
        case CandidateState.retryableFailed: ++result.retryableFailed; break;
        case CandidateState.permanentFailed: ++result.permanentFailed; break;
        }
        return result;
    }

    CandidateView[] snapshot() const {
        CandidateView[] result;
        foreach (record; records)
            result ~= CandidateView(copyInput(record.candidate), record.state,
                record.generation);
        result.sort!((a, b) => a.candidate.policyId < b.candidate.policyId ||
            (a.candidate.policyId == b.candidate.policyId &&
             a.candidate.canonicalLocator < b.candidate.canonicalLocator));
        return result;
    }

    bool lookup(CandidateKey key, out CandidateView result) const {
        auto index = find(key);
        if (index == size_t.max) return false;
        auto record = records[index];
        result = CandidateView(copyInput(record.candidate), record.state,
            record.generation);
        return true;
    }

private:
    Admission admit(CandidateInput input) {
        auto key = keyOf(input);
        if (sealed_) return Admission(AdmissionCode.refusedSealed, key);
        if (input.policyId.length == 0 || input.canonicalLocator.length == 0)
            return Admission(AdmissionCode.refusedInvalidIdentity, key);
        if (find(key) != size_t.max)
            return Admission(AdmissionCode.duplicate, key);
        if (input.hostKey.length == 0)
            return Admission(AdmissionCode.refusedInvalidHost, key);
        if (input.provenance.length > limits_.maxProvenanceBytes)
            return Admission(AdmissionCode.refusedProvenanceLimit, key);
        if (input.depth > limits_.maxDepth)
            return Admission(AdmissionCode.refusedDepthLimit, key);
        if (records.length >= limits_.maxPages)
            return Admission(AdmissionCode.refusedPageLimit, key);
        if (hostPages(input.hostKey) >= limits_.maxPagesPerHost)
            return Admission(AdmissionCode.refusedHostLimit, key);
        size_t bytes;
        if (!storedBytes(input, bytes) ||
                bytes > limits_.maxStoredBytes - storedBytes_)
            return Admission(AdmissionCode.refusedStoredByteLimit, key);

        Record record;
        record.candidate = copyInput(input);
        auto index = records.length;
        records ~= record;
        storedBytes_ += bytes;
        enqueue(index, false);
        return Admission(records[index].state == CandidateState.deferred ?
            AdmissionCode.admittedDeferred : AdmissionCode.admittedQueued,
            keyOf(records[index].candidate));
    }

    void enqueue(size_t index, bool retry) {
        auto record = &records[index];
        if (deferred.length != 0 || ready.length >= limits_.maxQueued) {
            record.state = CandidateState.deferred;
            record.deferredRetry = retry;
            deferred ~= index;
        } else {
            record.state = retry ? CandidateState.retryableFailed : CandidateState.queued;
            record.deferredRetry = false;
            ready ~= index;
        }
    }

    void promote() {
        while (ready.length < limits_.maxQueued && deferred.length != 0) {
            auto index = popFront(deferred);
            auto record = &records[index];
            require(record.state == CandidateState.deferred, "invalid deferred state");
            record.state = record.deferredRetry ? CandidateState.retryableFailed :
                CandidateState.queued;
            record.deferredRetry = false;
            ready ~= index;
        }
    }

    size_t find(CandidateKey key) const {
        foreach (index, record; records)
            if (record.candidate.policyId == key.policyId &&
                    record.candidate.canonicalLocator == key.canonicalLocator)
                return index;
        return size_t.max;
    }

    size_t hostPages(string host) const {
        size_t count;
        foreach (record; records) if (record.candidate.hostKey == host) ++count;
        return count;
    }
}

private CandidateKey keyOf(CandidateInput input) {
    return CandidateKey(input.policyId, input.canonicalLocator);
}

private CandidateInput copyInput(CandidateInput input) {
    return CandidateInput(input.policyId.idup, input.canonicalLocator.idup,
        input.hostKey.idup, input.depth, input.provenance.idup);
}

private bool storedBytes(CandidateInput input, out size_t result) {
    foreach (part; [input.policyId, input.canonicalLocator, input.hostKey,
            input.provenance]) {
        if (part.length > size_t.max - result) return false;
        result += part.length;
    }
    return true;
}

private size_t popFront(ref size_t[] values) {
    require(values.length != 0, "empty pending queue");
    auto result = values[0];
    values = values[1 .. $].dup;
    return result;
}

unittest {
    auto frontier = new UrlFrontier(FrontierLimits(4, 4, 2, 1, 1, 100, 20));
    auto input = CandidateInput("canonical:v1", "https://example/a", "example", 0, "seed");
    assert(frontier.admitSeed(input).code == AdmissionCode.admittedQueued);
    assert(frontier.admitSeed(input).code == AdmissionCode.duplicate);
    auto lease = frontier.takeLease();
    assert(lease.available && frontier.counts.activeLeases == 1);
    assert(frontier.finish(lease.lease, LeaseOutcome.completed).code == FinishCode.applied);
    assert(frontier.finish(lease.lease, LeaseOutcome.completed).code == FinishCode.notLeased);
    frontier.seal();
    assert(frontier.isComplete);
}
