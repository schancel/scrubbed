/// In-process test double proving the shared suite accepts a durable capability.
module experiments.frontier_conformance.durable_probe;

import domain.job_queue;

private enum durableDescriptor = FrontierBackendDescriptor(
    frontierContractName, currentFrontierContractVersion, true);

/// Adapts the semantic in-memory implementation while advertising the durable
/// capability. Persistence itself is deliberately outside this conformance test.
QueueOpenResult openDurableProbe(FrontierLimits limits,
        FrontierRequirements requirements) {
    auto memoryRequirements = requirements;
    memoryRequirements.requireProcessDurability = false;
    auto opened = openInMemoryJobQueue(limits, memoryRequirements);
    opened.backend = durableDescriptor;
    if (opened.code != QueueOpenCode.opened) return opened;
    opened.queue = new DurableProbeQueue(opened.queue);
    return opened;
}

private final class DurableProbeQueue : JobQueue {
    private JobQueue inner;

    this(JobQueue inner) { this.inner = inner; }

    override FrontierBackendDescriptor descriptor() const { return durableDescriptor; }
    override FrontierLimits limits() const { return inner.limits; }
    override bool isSealed() const { return inner.isSealed; }
    override bool isCanceled() const { return inner.isCanceled; }
    override bool isComplete() const { return inner.isComplete; }
    override Admission admit(CandidateInput candidate) { return inner.admit(candidate); }
    override void seal() { inner.seal(); }
    override void cancelLeasing() { inner.cancelLeasing(); }
    override void resumeLeasing() { inner.resumeLeasing(); }
    override FrontierCounts counts() const { return inner.counts; }
    override FrontierSnapshot snapshot(size_t maximumItems) const {
        return inner.snapshot(maximumItems);
    }
    override bool lookup(CandidateKey key, out CandidateView result) const {
        return inner.lookup(key, result);
    }
    override LeaseAttempt takeLease() { return inner.takeLease(); }
    override FinishResult finish(LeaseToken lease, LeaseOutcome outcome,
            const(CandidateInput)[] discoveries = null) {
        return inner.finish(lease, outcome, discoveries);
    }
    override ReclaimCode reclaim(LeaseToken lease) { return inner.reclaim(lease); }
}
