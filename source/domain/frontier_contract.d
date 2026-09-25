/// Versioned values shared by every URL-frontier backend.
module domain.frontier_contract;

enum frontierContractName = "scrubbed.frontier";

struct FrontierContractVersion {
    uint major;
    uint minor;
}

enum currentFrontierContractVersion = FrontierContractVersion(1, 0);

/// Backend facts that can change whether a caller may safely use it. Queue
/// ordering and lifecycle rules are deliberately not capabilities: every
/// conforming backend implements those same semantics.
struct FrontierBackendDescriptor {
    string contractName;
    FrontierContractVersion contractVersion;
    bool processDurable;
}

struct FrontierRequirements {
    string contractName = frontierContractName;
    FrontierContractVersion minimumVersion = currentFrontierContractVersion;
    bool requireProcessDurability;
}

enum QueueOpenCode : ubyte {
    opened,
    incompatibleContract,
    unsupportedProcessDurability,
}

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

enum LeaseUnavailable : ubyte {
    none,
    canceled,
    activeLimit,
    noQueuedWork,
    generationExhausted,
}

enum LeaseOutcome : ubyte { completed, retryableFailure, permanentFailure }

enum FinishCode : ubyte {
    applied,
    unknownCandidate,
    notLeased,
    staleGeneration,
    discoveryCountLimit,
    discoveryInputByteLimit,
}

enum ReclaimCode : ubyte { reclaimed, unknownCandidate, notLeased, staleGeneration }

enum SnapshotCode : ubyte { captured, itemLimit }

struct FrontierLimits {
    size_t maxPages;
    size_t maxPagesPerHost;
    size_t maxDepth;
    size_t maxQueued;
    size_t maxActiveLeases;
    size_t maxStoredBytes;
    size_t maxProvenanceBytes;
    size_t maxDiscoveriesPerFinish;
    size_t maxDiscoveryInputBytes;
}

/// The policy and canonical locator jointly form identity. All strings are
/// opaque: the frontier validates bounds but does no URL normalization.
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

struct FrontierSnapshot {
    SnapshotCode code;
    size_t requiredItems;
    CandidateView[] candidates;
}

bool satisfies(FrontierBackendDescriptor backend, FrontierRequirements required) {
    return backend.contractName == required.contractName &&
        backend.contractVersion.major == required.minimumVersion.major &&
        backend.contractVersion.minor >= required.minimumVersion.minor;
}
