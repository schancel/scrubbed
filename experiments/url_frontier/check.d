/// Release-mode model checker for the pure URL-frontier lifecycle.
module experiments.url_frontier.check;

import domain.url_frontier;
import std.random : Random, uniform;
import std.stdio : writeln;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("URL frontier checker: " ~ label);
}

private CandidateInput item(size_t number, size_t depth = 0,
        string host = "example", string policy = "canonical:v1") {
    import std.conv : to;
    auto text = number.to!string;
    return CandidateInput(policy, "opaque://" ~ text, host, depth, "from:" ~ text);
}

private FrontierLimits limits(size_t pages = 32, size_t host = 32,
        size_t depth = 4, size_t queued = 2, size_t active = 2,
        size_t bytes = 4096, size_t provenance = 32,
        size_t discoveries = 8, size_t discoveryBytes = 1024) {
    return FrontierLimits(pages, host, depth, queued, active, bytes, provenance,
        discoveries, discoveryBytes);
}

private void finishInputCapsAreAtomic() {
    auto frontier = new UrlFrontier(limits(3, 3, 1, 1, 1, 256, 8, 2, 48));
    frontier.admitSeed(item(1));
    auto lease = frontier.takeLease();
    frontier.admitSeed(item(9));
    frontier.admitSeed(item(10));
    auto beforeCounts = frontier.counts;
    auto beforeState = frontier.snapshot;

    auto countOverflow = frontier.finish(lease.lease, LeaseOutcome.completed,
        [item(2), item(3), item(4)]);
    need(countOverflow.code == FinishCode.discoveryCountLimit &&
        countOverflow.discoveries.length == 0, "finish discovery-count refusal");
    need(frontier.counts == beforeCounts && frontier.snapshot == beforeState,
        "count overflow leaves frontier unchanged");

    auto byteOverflow = frontier.finish(lease.lease, LeaseOutcome.completed,
        [item(2), item(3)]);
    need(byteOverflow.code == FinishCode.discoveryInputByteLimit &&
        byteOverflow.discoveries.length == 0, "finish discovery-byte refusal");
    need(frontier.counts == beforeCounts && frontier.snapshot == beforeState,
        "byte overflow leaves frontier unchanged");

    need(frontier.finish(lease.lease, LeaseOutcome.completed).code ==
        FinishCode.applied, "lease remains live after finish refusal");
    foreach (expected; [9, 10]) {
        auto pending = frontier.takeLease();
        need(pending.available && pending.candidate.canonicalLocator ==
            item(expected).canonicalLocator, "finish refusal preserves queue order");
        frontier.finish(pending.lease, LeaseOutcome.completed);
    }
    checkCaps(frontier);
}

private void completionAndMixedBatchEdges() {
    auto frontier = new UrlFrontier(limits(8, 8, 1, 1, 1));
    need(!frontier.isComplete, "open empty frontier is not complete");
    frontier.admitSeed(item(0));
    frontier.seal();
    need(!frontier.isComplete, "sealed queued frontier is not complete");
    auto lease = frontier.takeLease();
    need(lease.available, "sealed frontier remains leaseable while draining");
    need(frontier.finish(lease.lease, LeaseOutcome.completed).code ==
        FinishCode.applied && frontier.isComplete, "sealed frontier drains");

    auto mixed = new UrlFrontier(limits(8, 8, 1, 1, 1));
    mixed.admitSeed(item(0));
    auto producer = mixed.takeLease();
    auto result = mixed.finish(producer.lease, LeaseOutcome.completed,
        [item(1), item(2, 2), item(3)]);
    need(result.code == FinishCode.applied && result.discoveries.length == 3 &&
        result.discoveries[0].code == AdmissionCode.admittedQueued &&
        result.discoveries[1].code == AdmissionCode.refusedDepthLimit &&
        result.discoveries[2].code == AdmissionCode.admittedDeferred,
        "mixed valid/refused/valid discoveries");
    need(mixed.counts.pages == 3 && mixed.counts.completed == 1,
        "mixed batch commits valid discoveries and outcome");
    checkCaps(mixed);
}

private void indexedScaleDrain() {
    enum pages = 4096;
    auto frontier = new UrlFrontier(limits(pages, pages, 1, 64, 64,
        512 * 1024, 16));
    foreach (number; 0 .. pages)
        need(frontier.admitSeed(item(number)).code ==
            (number < 64 ? AdmissionCode.admittedQueued :
             AdmissionCode.admittedDeferred), "scale admission");
    checkCaps(frontier);
    size_t completed;
    while (completed != pages) {
        LeaseToken[] leases;
        foreach (_; 0 .. 64) {
            auto lease = frontier.takeLease();
            if (!lease.available) break;
            leases ~= lease.lease;
        }
        foreach (lease; leases) {
            need(frontier.finish(lease, LeaseOutcome.completed).code ==
                FinishCode.applied, "scale completion");
            ++completed;
        }
    }
    frontier.seal();
    need(frontier.isComplete, "scale drain");
}

private void checkCaps(UrlFrontier frontier) {
    auto count = frontier.counts;
    auto cap = frontier.limits;
    need(count.pages <= cap.maxPages, "page cap");
    need(count.queued <= cap.maxQueued, "queued cap");
    need(count.activeLeases <= cap.maxActiveLeases, "lease cap");
    need(count.storedBytes <= cap.maxStoredBytes, "stored-byte cap");
    need(count.pages == count.queued + count.deferred + count.activeLeases +
        count.completed + count.permanentFailed,
        "state accounting (retryable failures are queued)");
    need(count.retryableFailed <= count.queued, "retryable placement");
    auto candidates = frontier.snapshot;
    foreach (candidate; candidates) {
        size_t hostPages;
        foreach (other; candidates)
            if (candidate.candidate.hostKey == other.candidate.hostKey) ++hostPages;
        need(hostPages <= cap.maxPagesPerHost, "host cap invariant");
        need(candidate.candidate.depth <= cap.maxDepth, "depth cap invariant");
        need(candidate.candidate.provenance.length <= cap.maxProvenanceBytes,
            "provenance cap invariant");
    }
}

private void duplicatesAndCaps() {
    auto frontier = new UrlFrontier(limits(3, 1, 1, 1, 1, 80, 6));
    need(frontier.admitSeed(CandidateInput("", "opaque://bad", "example", 0, "")).code ==
        AdmissionCode.refusedInvalidIdentity, "empty identity refusal");
    need(frontier.admitSeed(CandidateInput("canonical:v1", "opaque://bad", "", 0, "")).code ==
        AdmissionCode.refusedInvalidHost, "empty host refusal");
    auto first = item(1);
    need(frontier.admitSeed(first).code == AdmissionCode.admittedQueued, "seed");
    auto distinctOpaqueLocator = first;
    distinctOpaqueLocator.canonicalLocator = "OPAQUE://1";
    distinctOpaqueLocator.hostKey = "other";
    need(frontier.admitSeed(distinctOpaqueLocator).code ==
        AdmissionCode.admittedDeferred, "no URL normalization");
    auto duplicate = first;
    duplicate.hostKey = "different";
    duplicate.depth = 99;
    duplicate.provenance = "oversized";
    need(frontier.admitSeed(duplicate).code == AdmissionCode.duplicate,
        "identity is policy plus locator");
    need(frontier.admitSeed(item(2, 0, "example")).code ==
        AdmissionCode.refusedHostLimit, "host refusal");
    need(frontier.admitSeed(item(3, 2, "depth")).code ==
        AdmissionCode.refusedDepthLimit, "depth refusal");
    auto provenance = item(4, 0, "provenance");
    provenance.provenance = "1234567";
    need(frontier.admitSeed(provenance).code ==
        AdmissionCode.refusedProvenanceLimit, "provenance refusal");

    auto pageFrontier = new UrlFrontier(limits(1));
    need(pageFrontier.admitSeed(item(1)).code == AdmissionCode.admittedQueued,
        "page setup");
    need(pageFrontier.admitSeed(item(2)).code == AdmissionCode.refusedPageLimit,
        "page refusal");

    auto byteFrontier = new UrlFrontier(limits(4, 4, 4, 2, 2, 24));
    need(byteFrontier.admitSeed(item(1)).code ==
        AdmissionCode.refusedStoredByteLimit, "stored-byte refusal");
    checkCaps(frontier);
    checkCaps(pageFrontier);
    checkCaps(byteFrontier);
}

private void saturationAndPromotion() {
    auto frontier = new UrlFrontier(limits(8, 8, 4, 1, 1));
    frontier.admitSeed(item(0));
    auto producer = frontier.takeLease();
    need(producer.available, "producer lease");
    auto completed = frontier.finish(producer.lease, LeaseOutcome.completed,
        [item(1), item(2), item(3)]);
    need(completed.code == FinishCode.applied && completed.discoveries.length == 3,
        "atomic discoveries");
    need(completed.discoveries[0].code == AdmissionCode.admittedQueued &&
        completed.discoveries[1].code == AdmissionCode.admittedDeferred &&
        completed.discoveries[2].code == AdmissionCode.admittedDeferred,
        "nonblocking saturation");
    foreach (expected; 1 .. 4) {
        auto lease = frontier.takeLease();
        need(lease.available && lease.candidate.canonicalLocator ==
            item(expected).canonicalLocator, "FIFO deterministic promotion");
        need(frontier.finish(lease.lease, LeaseOutcome.completed).code ==
            FinishCode.applied, "promoted completion");
    }
    frontier.seal();
    need(frontier.isComplete, "saturated drain completes");
    need(frontier.admitSeed(item(7)).code == AdmissionCode.refusedSealed,
        "sealed seed refusal");
    checkCaps(frontier);

    auto retryFrontier = new UrlFrontier(limits(8, 8, 4, 1, 1));
    retryFrontier.admitSeed(item(1));
    retryFrontier.admitSeed(item(2));
    retryFrontier.admitSeed(item(3));
    auto failed = retryFrontier.takeLease();
    retryFrontier.finish(failed.lease, LeaseOutcome.retryableFailure);
    foreach (expected; [2, 3, 1]) {
        auto lease = retryFrontier.takeLease();
        need(lease.available && lease.candidate.canonicalLocator ==
            item(expected).canonicalLocator, "retry joins deterministic FIFO tail");
        retryFrontier.finish(lease.lease, LeaseOutcome.completed);
    }
    checkCaps(retryFrontier);
}

private void generationsCancellationAndRaces() {
    auto frontier = new UrlFrontier(limits());
    auto unknown = LeaseToken(CandidateKey("canonical:v1", "opaque://missing"), 1);
    need(frontier.finish(unknown, LeaseOutcome.completed).code ==
        FinishCode.unknownCandidate, "unknown completion rejected");
    need(frontier.reclaim(unknown) == ReclaimCode.unknownCandidate,
        "unknown reclaim rejected");
    need(frontier.takeLease().unavailable == LeaseUnavailable.noQueuedWork,
        "empty frontier does not lease");
    frontier.admitSeed(item(1));
    auto first = frontier.takeLease();
    frontier.cancelLeasing();
    need(frontier.takeLease().unavailable == LeaseUnavailable.canceled,
        "cancellation stops leases");
    need(frontier.counts.pages == 1 && frontier.counts.activeLeases == 1,
        "cancellation preserves state");
    need(frontier.reclaim(first.lease) == ReclaimCode.reclaimed, "reclaim");
    CandidateView afterReclaim;
    need(frontier.lookup(first.lease.key, afterReclaim) &&
        afterReclaim.generation > first.lease.generation,
        "reclaim advances generation");
    need(frontier.finish(first.lease, LeaseOutcome.completed).code ==
        FinishCode.staleGeneration, "stale completion rejected");
    frontier.resumeLeasing();
    auto second = frontier.takeLease();
    need(second.available && second.lease.generation > afterReclaim.generation,
        "new lease generation");
    need(frontier.finish(second.lease, LeaseOutcome.retryableFailure).code ==
        FinishCode.applied, "retryable outcome");
    CandidateView retry;
    need(frontier.lookup(second.lease.key, retry) &&
        retry.state == CandidateState.retryableFailed, "retryable state");
    auto third = frontier.takeLease();
    frontier.seal();
    auto late = frontier.finish(third.lease, LeaseOutcome.permanentFailure, [item(2)]);
    need(late.code == FinishCode.applied && late.discoveries[0].code ==
        AdmissionCode.refusedSealed, "seal race rejects late discovery");
    need(frontier.finish(third.lease, LeaseOutcome.completed).code ==
        FinishCode.notLeased, "double completion rejected");
    need(frontier.isComplete && frontier.counts.permanentFailed == 1,
        "poison item drains");
    checkCaps(frontier);
}

private void activeLimitAndPolicyIdentity() {
    auto frontier = new UrlFrontier(limits(8, 8, 4, 4, 1));
    frontier.admitSeed(item(1));
    frontier.admitSeed(item(1, 0, "example", "canonical:v2"));
    auto lease = frontier.takeLease();
    need(frontier.takeLease().unavailable == LeaseUnavailable.activeLimit,
        "active lease cap");
    frontier.finish(lease.lease, LeaseOutcome.completed);
    auto otherPolicy = frontier.takeLease();
    need(otherPolicy.available && otherPolicy.candidate.policyId == "canonical:v2",
        "versioned policy identity");
    frontier.finish(otherPolicy.lease, LeaseOutcome.completed);
    checkCaps(frontier);
}

private void randomizedTraces() {
    foreach (seed; 1u .. 65u) {
        Random random = Random(seed);
        auto frontier = new UrlFrontier(limits(40, 12, 3, 3, 2, 1400, 16));
        LeaseToken[] live;
        size_t next;
        foreach (_; 0 .. 400) {
            auto action = uniform(0, 8, random);
            if (action <= 1) {
                auto candidate = item(next++, uniform(0, 6, random),
                    uniform(0, 2, random) == 0 ? "a" : "b");
                frontier.admitSeed(candidate);
            } else if (action == 2) {
                auto lease = frontier.takeLease();
                if (lease.available) live ~= lease.lease;
            } else if (action <= 5 && live.length != 0) {
                auto at = uniform(0, live.length, random);
                auto lease = live[at];
                live = live[0 .. at] ~ live[at + 1 .. $];
                auto outcome = action == 3 ? LeaseOutcome.completed :
                    action == 4 ? LeaseOutcome.retryableFailure :
                    LeaseOutcome.permanentFailure;
                CandidateInput[] found;
                if (uniform(0, 3, random) == 0) found ~= item(next++);
                need(frontier.finish(lease, outcome, found).code == FinishCode.applied,
                    "random finish");
            } else if (action == 6 && live.length != 0) {
                auto lease = live[$ - 1];
                live.length--;
                need(frontier.reclaim(lease) == ReclaimCode.reclaimed,
                    "random reclaim");
                need(frontier.finish(lease, LeaseOutcome.completed).code ==
                    FinishCode.staleGeneration, "random stale generation");
            } else if (action == 7) {
                frontier.cancelLeasing();
                need(frontier.takeLease().unavailable == LeaseUnavailable.canceled,
                    "random canceled lease");
                frontier.resumeLeasing();
            }
            checkCaps(frontier);
        }
        foreach (lease; live)
            need(frontier.finish(lease, LeaseOutcome.permanentFailure).code ==
                FinishCode.applied, "random live drain");
        while (true) {
            auto lease = frontier.takeLease();
            if (!lease.available) break;
            frontier.finish(lease.lease, LeaseOutcome.completed);
        }
        frontier.seal();
        need(frontier.isComplete, "random completion");
        checkCaps(frontier);
    }
}

void main() {
    duplicatesAndCaps();
    saturationAndPromotion();
    generationsCancellationAndRaces();
    activeLimitAndPolicyIdentity();
    finishInputCapsAreAtomic();
    completionAndMixedBatchEdges();
    indexedScaleDrain();
    randomizedTraces();
    writeln("URL frontier checker passed: 64 deterministic randomized traces");
}
