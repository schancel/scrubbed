/// Deterministic shared conformance suite for Frontier/JobQueue backends.
module experiments.frontier_conformance.conformance;

import domain.job_queue;
import std.conv : to;

alias QueueFactory = QueueOpenResult function(FrontierLimits, FrontierRequirements);

private void need(bool okay, string label) {
    if (!okay) throw new Exception("frontier conformance: " ~ label);
}

private CandidateInput item(size_t number, size_t depth = 0,
        string host = "example", string policy = "canonical:v1",
        string provenance = null) {
    auto text = number.to!string;
    return CandidateInput(policy, "opaque://" ~ text, host, depth,
        provenance.length ? provenance : "from:" ~ text);
}

private FrontierLimits limits(size_t pages = 16, size_t host = 16,
        size_t depth = 3, size_t queued = 2, size_t active = 2,
        size_t stored = 4096, size_t provenance = 32,
        size_t discoveries = 4, size_t discoveryBytes = 512) {
    return FrontierLimits(pages, host, depth, queued, active, stored,
        provenance, discoveries, discoveryBytes);
}

private JobQueue open(QueueFactory factory, FrontierLimits bounded = limits()) {
    auto opened = factory(bounded, FrontierRequirements());
    need(opened.code == QueueOpenCode.opened && opened.queue !is null, "open");
    need(opened.backend == opened.queue.descriptor, "descriptor is stable");
    return opened.queue;
}

private string stateLine(JobQueue queue) {
    auto counts = queue.counts;
    auto snap = queue.snapshot(counts.pages);
    need(snap.code == SnapshotCode.captured &&
        snap.requiredItems == counts.pages, "complete bounded snapshot");
    string result = counts.pages.to!string ~ "/" ~ counts.queued.to!string ~
        "/" ~ counts.deferred.to!string ~ "/" ~ counts.activeLeases.to!string ~
        "/" ~ counts.completed.to!string ~ "/" ~
        counts.retryableFailed.to!string ~ "/" ~
        counts.permanentFailed.to!string ~ "/" ~ counts.storedBytes.to!string;
    foreach (entry; snap.candidates)
        result ~= "\t" ~ entry.candidate.policyId ~ "|" ~
            entry.candidate.canonicalLocator ~ "|" ~
            entry.candidate.hostKey ~ "|" ~ entry.candidate.depth.to!string ~
            "|" ~ entry.candidate.provenance ~ "|" ~
            entry.state.to!string ~ "|" ~ entry.generation.to!string;
    return result;
}

private void checkCaps(JobQueue queue) {
    auto count = queue.counts;
    auto cap = queue.limits;
    need(count.pages <= cap.maxPages, "page cap");
    need(count.queued <= cap.maxQueued, "queue cap");
    need(count.activeLeases <= cap.maxActiveLeases, "active cap");
    need(count.storedBytes <= cap.maxStoredBytes, "stored-byte cap");
    need(count.pages == count.queued + count.deferred + count.activeLeases +
        count.completed + count.permanentFailed, "state accounting");
    need(count.retryableFailed <= count.queued, "retryable placement");
    auto snap = queue.snapshot(cap.maxPages);
    need(snap.code == SnapshotCode.captured, "limit-bounded snapshot");
    foreach (candidate; snap.candidates) {
        size_t hostPages;
        foreach (other; snap.candidates)
            if (candidate.candidate.hostKey == other.candidate.hostKey) ++hostPages;
        need(hostPages <= cap.maxPagesPerHost, "host cap");
        need(candidate.candidate.depth <= cap.maxDepth, "depth cap");
        need(candidate.candidate.provenance.length <= cap.maxProvenanceBytes,
            "provenance cap");
    }
}

private void requirementsArePreMutation(QueueFactory factory) {
    auto wrongName = FrontierRequirements("other.frontier",
        currentFrontierContractVersion, false);
    auto named = factory(FrontierLimits(), wrongName);
    need(named.code == QueueOpenCode.incompatibleContract && named.queue is null,
        "identity refusal creates no queue");
    auto wrongMajor = FrontierRequirements(frontierContractName,
        FrontierContractVersion(2, 0), false);
    auto major = factory(FrontierLimits(), wrongMajor);
    need(major.code == QueueOpenCode.incompatibleContract && major.queue is null,
        "major refusal creates no queue");
    auto newerMinor = FrontierRequirements(frontierContractName,
        FrontierContractVersion(1, 1), false);
    auto minor = factory(FrontierLimits(), newerMinor);
    need(minor.code == QueueOpenCode.incompatibleContract && minor.queue is null,
        "minor refusal creates no queue");
    auto durable = FrontierRequirements(frontierContractName,
        currentFrontierContractVersion, true);
    auto unsupported = factory(FrontierLimits(), durable);
    need(unsupported.code == QueueOpenCode.unsupportedProcessDurability &&
        unsupported.queue is null && !unsupported.backend.processDurable,
        "durability refusal creates no queue");
}

private void admissionLimits(QueueFactory factory) {
    auto queue = open(factory, limits(3, 1, 1, 1, 1, 80, 6));
    need(queue.admit(CandidateInput("", "opaque://bad", "example", 0, "")).code ==
        AdmissionCode.refusedInvalidIdentity, "identity limit");
    need(queue.admit(CandidateInput("canonical:v1", "opaque://bad", "", 0, "")).code ==
        AdmissionCode.refusedInvalidHost, "host identity limit");
    need(queue.admit(item(1)).code == AdmissionCode.admittedQueued, "seed");
    auto duplicate = item(1, 99, "different", "canonical:v1", "oversized");
    need(queue.admit(duplicate).code == AdmissionCode.duplicate, "identity policy");
    need(queue.admit(item(1, 0, "other", "canonical:v2")).code ==
        AdmissionCode.admittedDeferred, "version is identity");
    need(queue.admit(item(2, 0, "example")).code ==
        AdmissionCode.refusedHostLimit, "host limit");
    need(queue.admit(item(3, 2, "depth")).code ==
        AdmissionCode.refusedDepthLimit, "depth limit");
    need(queue.admit(item(4, 0, "provenance", "canonical:v1", "1234567")).code ==
        AdmissionCode.refusedProvenanceLimit, "provenance limit");
    checkCaps(queue);

    auto pages = open(factory, limits(1));
    need(pages.admit(item(1)).code == AdmissionCode.admittedQueued,
        "page limit setup");
    need(pages.admit(item(2)).code == AdmissionCode.refusedPageLimit,
        "page limit");

    auto stored = open(factory, limits(2, 2, 1, 1, 1, 24));
    need(stored.admit(item(1)).code == AdmissionCode.refusedStoredByteLimit,
        "stored-byte limit");
    checkCaps(stored);
}

private void leasesRetriesAndTermination(QueueFactory factory) {
    auto queue = open(factory, limits(8, 8, 2, 1, 1));
    need(queue.takeLease().unavailable == LeaseUnavailable.noQueuedWork,
        "truthful open no-work");
    need(!queue.isComplete, "open empty is not complete");
    queue.admit(item(1));
    queue.admit(item(2));
    auto first = queue.takeLease();
    need(first.available && first.lease.generation == 1, "first generation");
    need(queue.takeLease().unavailable == LeaseUnavailable.activeLimit,
        "active limit");
    queue.cancelLeasing();
    need(queue.takeLease().unavailable == LeaseUnavailable.canceled,
        "cancellation");
    need(queue.reclaim(first.lease) == ReclaimCode.reclaimed, "reclaim");
    need(queue.finish(first.lease, LeaseOutcome.completed).code ==
        FinishCode.staleGeneration, "stale completion");
    queue.resumeLeasing();
    auto second = queue.takeLease();
    need(second.candidate.canonicalLocator == item(2).canonicalLocator,
        "reclaim joins FIFO tail");
    need(queue.finish(second.lease, LeaseOutcome.retryableFailure).code ==
        FinishCode.applied, "retryable finish");
    auto reclaimed = queue.takeLease();
    need(reclaimed.candidate.canonicalLocator == item(1).canonicalLocator &&
        reclaimed.lease.generation > first.lease.generation, "reclaimed generation");
    need(queue.finish(reclaimed.lease, LeaseOutcome.completed).code ==
        FinishCode.applied, "reclaimed finish");
    auto retry = queue.takeLease();
    need(retry.candidate.canonicalLocator == item(2).canonicalLocator,
        "retry tail");
    queue.seal();
    need(queue.finish(retry.lease, LeaseOutcome.permanentFailure).code ==
        FinishCode.applied, "poison finish");
    need(queue.finish(retry.lease, LeaseOutcome.completed).code ==
        FinishCode.notLeased, "double completion");
    need(queue.isComplete && queue.counts.permanentFailed == 1,
        "sealed termination");
    need(queue.admit(item(3)).code == AdmissionCode.refusedSealed,
        "sealed admission");
    checkCaps(queue);
}

private void finishIsAtomicAndSaturationDrains(QueueFactory factory) {
    auto queue = open(factory, limits(8, 8, 2, 1, 1, 512, 16, 2, 128));
    queue.admit(item(0));
    auto producer = queue.takeLease();
    auto before = stateLine(queue);
    auto countRefusal = queue.finish(producer.lease, LeaseOutcome.completed,
        [item(1), item(2), item(3)]);
    need(countRefusal.code == FinishCode.discoveryCountLimit &&
        stateLine(queue) == before, "discovery count refusal is pre-mutation");
    auto byteRefusal = queue.finish(producer.lease, LeaseOutcome.completed,
        [item(10, 0, "host-that-is-deliberately-long-enough-to-overflow-the-batch-input-budget"),
         item(11, 0, "host-that-is-deliberately-long-enough-to-overflow-the-batch-input-budget")]);
    need(byteRefusal.code == FinishCode.discoveryInputByteLimit &&
        stateLine(queue) == before, "discovery bytes refusal is pre-mutation");

    auto applied = queue.finish(producer.lease, LeaseOutcome.completed,
        [item(1), item(2)]);
    need(applied.code == FinishCode.applied &&
        applied.discoveries[0].code == AdmissionCode.admittedQueued &&
        applied.discoveries[1].code == AdmissionCode.admittedDeferred,
        "finish-with-discovery saturation");
    foreach (expected; 1 .. 3) {
        auto lease = queue.takeLease();
        need(lease.available && lease.candidate.canonicalLocator ==
            item(expected).canonicalLocator, "deterministic promotion");
        queue.finish(lease.lease, LeaseOutcome.completed);
    }
    queue.seal();
    need(queue.isComplete, "saturated queue drains");
    checkCaps(queue);
}

private void snapshotsAreBoundedAndReadOnly(QueueFactory factory) {
    auto queue = open(factory);
    queue.admit(item(2));
    queue.admit(item(1));
    auto before = stateLine(queue);
    auto refused = queue.snapshot(1);
    need(refused.code == SnapshotCode.itemLimit && refused.requiredItems == 2 &&
        refused.candidates.length == 0, "bounded snapshot refusal");
    need(stateLine(queue) == before, "snapshot refusal is read-only");
    auto captured = queue.snapshot(2);
    need(captured.code == SnapshotCode.captured &&
        captured.candidates[0].candidate.canonicalLocator == item(1).canonicalLocator,
        "snapshot stable identity order");
}

private string[] replay(QueueFactory factory) {
    auto queue = open(factory, limits(10, 5, 2, 2, 2));
    string[] trace;
    trace ~= queue.admit(item(2)).code.to!string ~ "\t" ~ stateLine(queue);
    trace ~= queue.admit(item(1)).code.to!string ~ "\t" ~ stateLine(queue);
    trace ~= queue.admit(item(3, 3)).code.to!string ~ "\t" ~ stateLine(queue);
    auto first = queue.takeLease();
    trace ~= first.lease.generation.to!string ~ "\t" ~ stateLine(queue);
    auto finish = queue.finish(first.lease, LeaseOutcome.completed, [item(4)]);
    trace ~= finish.code.to!string ~ "/" ~ finish.discoveries[0].code.to!string ~
        "\t" ~ stateLine(queue);
    auto second = queue.takeLease();
    queue.reclaim(second.lease);
    trace ~= queue.finish(second.lease, LeaseOutcome.completed).code.to!string ~
        "\t" ~ stateLine(queue);
    while (true) {
        auto lease = queue.takeLease();
        if (!lease.available) break;
        queue.finish(lease.lease, LeaseOutcome.completed);
    }
    queue.seal();
    trace ~= queue.isComplete.to!string ~ "\t" ~ stateLine(queue);
    return trace;
}

/// Runs the reusable semantic suite and returns a canonical replay transcript.
string[] runConformance(QueueFactory factory) {
    requirementsArePreMutation(factory);
    admissionLimits(factory);
    leasesRetriesAndTermination(factory);
    finishIsAtomicAndSaturationDrains(factory);
    snapshotsAreBoundedAndReadOnly(factory);
    auto first = replay(factory);
    auto second = replay(factory);
    need(first == second, "equivalent traces are identical");
    return first;
}
