/// Backend-neutral pipeline seam for bounded URL-frontier work.
module domain.job_queue;

public import domain.frontier_contract;
import domain.url_frontier : UrlFrontier;

/// Admission and lifecycle inspection owned by a frontier.
interface Frontier {
    FrontierBackendDescriptor descriptor() const;
    FrontierLimits limits() const;
    bool isSealed() const;
    bool isCanceled() const;
    bool isComplete() const;
    Admission admit(CandidateInput candidate);
    void seal();
    void cancelLeasing();
    void resumeLeasing();
    FrontierCounts counts() const;
    FrontierSnapshot snapshot(size_t maximumItems) const;
    bool lookup(CandidateKey key, out CandidateView result) const;
}

/// The pipeline-facing queue. Finish applies the producing lease outcome before
/// admitting its discoveries, as one backend transaction boundary.
interface JobQueue : Frontier {
    LeaseAttempt takeLease();
    FinishResult finish(LeaseToken lease, LeaseOutcome outcome,
        const(CandidateInput)[] discoveries = null);
    ReclaimCode reclaim(LeaseToken lease);
}

struct QueueOpenResult {
    QueueOpenCode code;
    FrontierBackendDescriptor backend;
    JobQueue queue;
}

private enum memoryDescriptor = FrontierBackendDescriptor(
    frontierContractName, currentFrontierContractVersion, false);

/// Rejects incompatible requirements before allocating mutable frontier state.
QueueOpenResult openInMemoryJobQueue(FrontierLimits limits,
        FrontierRequirements requirements = FrontierRequirements()) {
    QueueOpenResult result;
    result.backend = memoryDescriptor;
    if (!memoryDescriptor.satisfies(requirements)) {
        result.code = QueueOpenCode.incompatibleContract;
        return result;
    }
    if (requirements.requireProcessDurability) {
        result.code = QueueOpenCode.unsupportedProcessDurability;
        return result;
    }
    result.queue = new InMemoryJobQueue(limits);
    result.code = QueueOpenCode.opened;
    return result;
}

private final class InMemoryJobQueue : JobQueue {
    private UrlFrontier state;

    this(FrontierLimits limits) { state = new UrlFrontier(limits); }

    override FrontierBackendDescriptor descriptor() const { return memoryDescriptor; }
    override FrontierLimits limits() const { return state.limits; }
    override bool isSealed() const { return state.isSealed; }
    override bool isCanceled() const { return state.isCanceled; }
    override bool isComplete() const { return state.isComplete; }
    override Admission admit(CandidateInput candidate) { return state.admitSeed(candidate); }
    override void seal() { state.seal(); }
    override void cancelLeasing() { state.cancelLeasing(); }
    override void resumeLeasing() { state.resumeLeasing(); }
    override FrontierCounts counts() const { return state.counts; }

    override FrontierSnapshot snapshot(size_t maximumItems) const {
        auto required = state.counts.pages;
        if (required > maximumItems)
            return FrontierSnapshot(SnapshotCode.itemLimit, required, null);
        return FrontierSnapshot(SnapshotCode.captured, required, state.snapshot);
    }

    override bool lookup(CandidateKey key, out CandidateView result) const {
        return state.lookup(key, result);
    }

    override LeaseAttempt takeLease() { return state.takeLease(); }

    override FinishResult finish(LeaseToken lease, LeaseOutcome outcome,
            const(CandidateInput)[] discoveries = null) {
        return state.finish(lease, outcome, discoveries);
    }

    override ReclaimCode reclaim(LeaseToken lease) { return state.reclaim(lease); }
}
