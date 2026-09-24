/// Bounded, local-only admission for the CLI's file walk.
module effects.bounded_input;

import core.atomic : atomicLoad, atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.time : MonoTime, ticksToNSecs;
version (Posix) {
    import core.sys.posix.time : timespec;
    version (OSX) {
        private enum CLOCK_THREAD_CPUTIME_ID = 16;
        private extern(C) int clock_gettime(int, timespec*);
    } else import core.sys.posix.time : CLOCK_THREAD_CPUTIME_ID, clock_gettime;
}
version (Windows) import core.sys.windows.winbase : FILETIME,
    GetCurrentThread, GetThreadTimes;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.parallelism : TaskPool, task;

struct InputLimits {
    size_t queuedDocuments;
    ulong reservedBytes;
    size_t workerDescriptors;
}

struct InputCounts {
    size_t queuedDocuments;
    ulong reservedBytes;
    size_t workerDescriptors;
    size_t peakQueuedDocuments;
    ulong peakReservedBytes;
    size_t peakWorkerDescriptors;
    size_t submitted;
    size_t succeeded;
    size_t failed;
    size_t skipped;
}

/// Caller-owned, fixed-cardinality coordination evidence. A null reference is
/// the shipping default and executes no clock reads or metric locking.
/// Transform nanoseconds are per-worker-thread CPU; other phase durations and
/// the top-level wall duration use the monotonic elapsed clock. Version 2
/// distinguishes this CPU meaning from the elapsed transform time emitted by v1.
enum CoordinationPhaseV2 {
    discovery, sourceStat, ordinalAssignment, admissionWait,
    acceptedWorkerQueue, descriptorWait, descriptorHold, transform,
    orderedResultWait, atomicPublication, shutdownJoin, count
}

struct CoordinationMetricValueV2 {
    ulong calls;
    ulong units;
    ulong nanoseconds;
}

final class CoordinationMetricsV2 {
    private shared ulong[CoordinationPhaseV2.count] calls;
    private shared ulong[CoordinationPhaseV2.count] units;
    private shared ulong[CoordinationPhaseV2.count] nanoseconds;
    private InputLimits limits;
    private InputCounts counts;
    private long wallStarted;
    private ulong wallNanoseconds;

    this() {
        wallStarted = MonoTime.currTime.ticks;
    }

    void setLimits(InputLimits value) {
        limits = value;
    }

    void setCounts(InputCounts value) {
        counts = value;
    }

    void finishWall() {
        auto elapsed = MonoTime.currTime.ticks - wallStarted;
        if (wallNanoseconds == 0 && elapsed > 0)
            wallNanoseconds = ticksToNanoseconds(elapsed);
    }

    void record(CoordinationPhaseV2 phase, ulong units = 0,
            long started = 0) {
        auto ended = started == 0 ? 0L : MonoTime.currTime.ticks;
        recordInterval(phase, units, started, ended);
    }

    void recordInterval(CoordinationPhaseV2 phase, ulong units,
            long started, long ended) {
        auto elapsed = started == 0 ? 0L : ended - started;
        calls[phase].atomicOp!"+="(1);
        this.units[phase].atomicOp!"+="(units);
        if (elapsed > 0)
            nanoseconds[phase].atomicOp!"+="(ticksToNanoseconds(elapsed));
    }

    void recordThreadCpu(CoordinationPhaseV2 phase, ulong units,
            long startedNanoseconds) {
        auto elapsed = threadCpuNanoseconds() - startedNanoseconds;
        calls[phase].atomicOp!"+="(1);
        this.units[phase].atomicOp!"+="(units);
        if (elapsed > 0)
            nanoseconds[phase].atomicOp!"+="(cast(ulong)elapsed);
    }

    string json() {
        static immutable names = ["discovery", "source_stat",
            "ordinal_assignment", "admission_wait", "accepted_worker_queue",
            "descriptor_wait", "descriptor_hold", "transform",
            "ordered_result_wait", "atomic_publication", "shutdown_join"];
        CoordinationMetricValueV2[CoordinationPhaseV2.count] snapshot;
        InputLimits capturedLimits;
        InputCounts capturedCounts;
        ulong capturedWall;
        foreach (index; 0 .. cast(size_t)CoordinationPhaseV2.count)
            snapshot[index] = CoordinationMetricValueV2(
                calls[index].atomicLoad,
                units[index].atomicLoad,
                nanoseconds[index].atomicLoad);
        capturedLimits = limits;
        capturedCounts = counts;
        capturedWall = wallNanoseconds;
        enforce(capturedCounts.submitted == capturedCounts.succeeded +
            capturedCounts.failed + capturedCounts.skipped,
            "coordination metrics terminal count mismatch");
        enforce(capturedCounts.queuedDocuments == 0 &&
            capturedCounts.reservedBytes == 0 &&
            capturedCounts.workerDescriptors == 0,
            "coordination metrics retained reservations");
        enforce(capturedCounts.peakQueuedDocuments <= capturedLimits.queuedDocuments &&
            capturedCounts.peakReservedBytes <= capturedLimits.reservedBytes &&
            capturedCounts.peakWorkerDescriptors <= capturedLimits.workerDescriptors,
            "coordination metrics peak exceeded configured limit");
        auto result = appender!string;
        result.put(`{"schema":"scrubbed.coordination-metrics.v2","version":2,`);
        result.put(`"wall_nanoseconds":`); result.put(capturedWall.to!string);
        result.put(`,"limits":{"queued_documents":`);
        result.put(capturedLimits.queuedDocuments.to!string);
        result.put(`,"reserved_bytes":`); result.put(capturedLimits.reservedBytes.to!string);
        result.put(`,"worker_descriptors":`);
        result.put(capturedLimits.workerDescriptors.to!string);
        result.put(`},"counts":{"queued_documents":`);
        result.put(capturedCounts.queuedDocuments.to!string);
        result.put(`,"reserved_bytes":`); result.put(capturedCounts.reservedBytes.to!string);
        result.put(`,"worker_descriptors":`);
        result.put(capturedCounts.workerDescriptors.to!string);
        result.put(`,"peak_queued_documents":`);
        result.put(capturedCounts.peakQueuedDocuments.to!string);
        result.put(`,"peak_reserved_bytes":`);
        result.put(capturedCounts.peakReservedBytes.to!string);
        result.put(`,"peak_worker_descriptors":`);
        result.put(capturedCounts.peakWorkerDescriptors.to!string);
        result.put(`,"submitted":`); result.put(capturedCounts.submitted.to!string);
        result.put(`,"succeeded":`); result.put(capturedCounts.succeeded.to!string);
        result.put(`,"failed":`); result.put(capturedCounts.failed.to!string);
        result.put(`,"skipped":`); result.put(capturedCounts.skipped.to!string);
        result.put(`},"phases":{`);
        foreach (index, name; names) {
            if (index) result.put(',');
            auto value = snapshot[index];
            result.put('"'); result.put(name); result.put(`":{"calls":`);
            result.put(value.calls.to!string); result.put(`,"units":`);
            result.put(value.units.to!string); result.put(`,"nanoseconds":`);
            result.put(value.nanoseconds.to!string); result.put('}');
        }
        result.put("}}");
        return result.data;
    }
}

long beginCoordinationMetricV2(CoordinationMetricsV2 metrics) {
    return metrics is null ? 0 : MonoTime.currTime.ticks;
}

long endCoordinationMetricV2(CoordinationMetricsV2 metrics) {
    return metrics is null ? 0 : MonoTime.currTime.ticks;
}

private ulong ticksToNanoseconds(long ticks) {
    return cast(ulong)ticksToNSecs(ticks);
}

long beginCoordinationThreadCpuMetricV2(CoordinationMetricsV2 metrics) {
    return metrics is null ? 0 : threadCpuNanoseconds();
}

private long threadCpuNanoseconds() {
    version (Posix) {
        timespec value;
        enforce(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0,
            "thread CPU clock unavailable");
        return cast(long)value.tv_sec * 1_000_000_000L + value.tv_nsec;
    } else version (Windows) {
        FILETIME created, exited, kernel, user;
        enforce(GetThreadTimes(GetCurrentThread(), &created, &exited,
            &kernel, &user) != 0, "thread CPU clock unavailable");
        ulong kernelTicks = (cast(ulong)kernel.dwHighDateTime << 32) |
            kernel.dwLowDateTime;
        ulong userTicks = (cast(ulong)user.dwHighDateTime << 32) |
            user.dwLowDateTime;
        return cast(long)((kernelTicks + userTicks) * 100);
    } else static assert(0, "unsupported thread CPU clock platform");
}

/// The producer owns traversal. The scheduler owns all reservations and joins
/// every submitted task before returning. The descriptor token covers the
/// entire processing callback, which may open the input and write output.
final class BoundedInput {
    private Mutex mutex;
    private Condition changed;
    private TaskPool pool;
    private InputLimits limits;
    private InputCounts counts;
    private size_t nextDescriptorSequence;
    private bool cancelled;
    private Throwable fatalFailure;
    private void delegate(string, ulong) process;
    private void delegate(string, Throwable) reportFailure;
    private bool delegate(Throwable) isFatal;
    private CoordinationMetricsV2 metrics;

    this(InputLimits limits, size_t threads,
         void delegate(string, ulong) process,
         void delegate(string, Throwable) reportFailure,
         bool delegate(Throwable) isFatal = null,
         CoordinationMetricsV2 metrics = null) {
        if (!limits.queuedDocuments || !limits.reservedBytes ||
            !limits.workerDescriptors || !threads)
            throw new Exception("input limits and threads must be positive");
        this.limits = limits;
        this.process = process;
        this.reportFailure = reportFailure;
        this.isFatal = isFatal;
        this.metrics = metrics;
        if (metrics !is null) metrics.setLimits(InputLimits(
            limits.queuedDocuments, limits.reservedBytes,
            threads < limits.workerDescriptors ? threads : limits.workerDescriptors));
        mutex = new Mutex;
        changed = new Condition(mutex);
        // finish(true) enlists its caller as a worker. Keep the total
        // processing callbacks within --threads even when the descriptor
        // ceiling is configured higher than the thread count.
        if (threads > 1)
            pool = new TaskPool(threads - 1);
    }

    /// false means a prior fault or explicit cancellation stopped admission.
    bool submit(string path, ulong bytes) {
        auto admissionStarted = beginCoordinationMetricV2(metrics);
        mutex.lock();
        if (cancelled) {
            mutex.unlock();
            return false;
        }
        if (bytes > limits.reservedBytes) {
            mutex.unlock();
            throw new Exception("input exceeds --max-input-bytes: " ~ path);
        }
        while (!cancelled && (counts.queuedDocuments == limits.queuedDocuments ||
            bytes > limits.reservedBytes - counts.reservedBytes))
            changed.wait();
        if (cancelled) {
            mutex.unlock();
            return false;
        }
        auto sequence = counts.submitted;
        ++counts.queuedDocuments;
        counts.reservedBytes += bytes;
        ++counts.submitted;
        if (counts.queuedDocuments > counts.peakQueuedDocuments)
            counts.peakQueuedDocuments = counts.queuedDocuments;
        if (counts.reservedBytes > counts.peakReservedBytes)
            counts.peakReservedBytes = counts.reservedBytes;
        mutex.unlock();

        if (metrics !is null)
            metrics.record(CoordinationPhaseV2.admissionWait, bytes,
                admissionStarted);
        auto acceptedAt = beginCoordinationMetricV2(metrics);

        if (pool is null) {
            execute(path, bytes, sequence, acceptedAt);
        } else {
            try {
                auto work = task!executeTask(this, path, bytes, sequence,
                    acceptedAt);
                pool.put(work);
            } catch (Exception error) {
                mutex.lock();
                --counts.queuedDocuments;
                counts.reservedBytes -= bytes;
                --counts.submitted;
                changed.notifyAll();
                mutex.unlock();
                throw error;
            }
        }
        return true;
    }

    private static void executeTask(BoundedInput self, string path, ulong bytes,
            size_t sequence, long acceptedAt) {
        self.execute(path, bytes, sequence, acceptedAt);
    }

    private void execute(string path, ulong bytes, size_t sequence,
            long acceptedAt) {
        if (metrics !is null)
            metrics.record(CoordinationPhaseV2.acceptedWorkerQueue, bytes,
                acceptedAt);
        auto descriptorWaitStarted = beginCoordinationMetricV2(metrics);
        mutex.lock();
        --counts.queuedDocuments;
        changed.notifyAll();
        // std.parallelism dequeues FIFO, but several dequeued tasks race before
        // this descriptor gate. Preserve submission order here so a later
        // canonical file cannot consume a scarce descriptor while waiting for
        // an earlier file's ordered publication turn.
        while (!cancelled && (sequence != nextDescriptorSequence ||
                counts.workerDescriptors == limits.workerDescriptors))
            changed.wait();
        if (cancelled) {
            counts.reservedBytes -= bytes;
            ++counts.skipped;
            changed.notifyAll();
            mutex.unlock();
            return;
        }
        ++counts.workerDescriptors;
        ++nextDescriptorSequence;
        if (counts.workerDescriptors > counts.peakWorkerDescriptors)
            counts.peakWorkerDescriptors = counts.workerDescriptors;
        changed.notifyAll();
        mutex.unlock();

        if (metrics !is null)
            metrics.record(CoordinationPhaseV2.descriptorWait, bytes,
                descriptorWaitStarted);
        auto descriptorHoldStarted = beginCoordinationMetricV2(metrics);

        bool success;
        try {
            process(path, bytes);
            success = true;
        } catch (Throwable error) {
            bool fatal = isFatal !is null && isFatal(error);
            if (fatal) stopFor(error);
            try {
                // Report while this task still owns its descriptor and byte token.
                reportFailure(path, error);
            } catch (Throwable reportError) {
                stopFor(reportError);
            }
        } finally {
            mutex.lock();
            --counts.workerDescriptors;
            counts.reservedBytes -= bytes;
            if (success) ++counts.succeeded;
            else ++counts.failed;
            changed.notifyAll();
            mutex.unlock();
            auto descriptorHoldEnded = endCoordinationMetricV2(metrics);
            if (metrics !is null)
                metrics.recordInterval(CoordinationPhaseV2.descriptorHold,
                    bytes, descriptorHoldStarted, descriptorHoldEnded);
        }
    }

    void cancel() {
        mutex.lock();
        cancelled = true;
        changed.notifyAll();
        mutex.unlock();
    }

    private void stopFor(Throwable error) {
        mutex.lock();
        if (fatalFailure is null) fatalFailure = error;
        cancelled = true;
        changed.notifyAll();
        mutex.unlock();
    }

    Throwable fatal() {
        mutex.lock();
        auto result = fatalFailure;
        mutex.unlock();
        return result;
    }

    InputCounts finish() {
        auto started = beginCoordinationMetricV2(metrics);
        if (pool !is null) pool.finish(true);
        mutex.lock();
        auto result = counts;
        mutex.unlock();
        if (metrics !is null) {
            metrics.record(CoordinationPhaseV2.shutdownJoin, 0, started);
            metrics.setCounts(result);
        }
        return result;
    }

    InputCounts snapshot() {
        mutex.lock();
        auto result = counts;
        mutex.unlock();
        return result;
    }
}

unittest {
    import core.atomic : atomicLoad, atomicOp;
    import core.thread : Thread;
    import core.sync.semaphore : Semaphore;
    import std.conv : to;
    import core.time : msecs;
    import std.json : parseJSON;

    auto overflowBoundary = long.max / 1_000_000_000L + 1;
    assert(ticksToNanoseconds(overflowBoundary) ==
        cast(ulong)ticksToNSecs(overflowBoundary));

    auto cpuStarted = threadCpuNanoseconds();
    Thread.sleep(100.msecs);
    auto sleptCpu = threadCpuNanoseconds() - cpuStarted;
    assert(sleptCpu >= 0 && sleptCpu < 50_000_000L,
        "thread CPU clock advanced like wall time while sleeping");

    auto metrics = new CoordinationMetricsV2;
    metrics.setLimits(InputLimits(1, 1, 1));
    metrics.setCounts(InputCounts.init);
    Thread.sleep(1.msecs);
    metrics.finishWall();
    auto metricsJson = parseJSON(metrics.json());
    assert(metricsJson["schema"].str == "scrubbed.coordination-metrics.v2" &&
        metricsJson["version"].integer == 2 &&
        metricsJson["wall_nanoseconds"].integer > 0);

    foreach (threads; [1, 4]) {
        shared size_t completed;
        auto scheduler = new BoundedInput(InputLimits(2, 7, 1), threads,
            (string path, ulong bytes) {
                assert(bytes == 7);
                Thread.sleep(1.msecs);
                completed.atomicOp!"+="(1);
            },
            (string path, Throwable error) { assert(0, error.msg); });
        foreach (i; 0 .. 128)
            assert(scheduler.submit(i.to!string, 7));
        auto result = scheduler.finish();
        assert(completed.atomicLoad == 128);
        assert(result.submitted == 128 && result.succeeded == 128);
        assert(result.queuedDocuments == 0 && result.reservedBytes == 0 &&
            result.workerDescriptors == 0);
        assert(result.peakQueuedDocuments <= 2 && result.peakReservedBytes <= 7 &&
            result.peakWorkerDescriptors <= 1);
    }

    string[] acquisitionOrder;
    auto orderMutex = new Mutex;
    auto ordered = new BoundedInput(InputLimits(8, 8, 1), 4,
        (string path, ulong bytes) {
            orderMutex.lock();
            acquisitionOrder ~= path;
            orderMutex.unlock();
        },
        (string path, Throwable error) { assert(0, error.msg); });
    foreach (i; 0 .. 64) assert(ordered.submit(i.to!string, 1));
    auto orderedCounts = ordered.finish();
    assert(orderedCounts.succeeded == 64 && acquisitionOrder.length == 64);
    foreach (i, path; acquisitionOrder) assert(path == i.to!string);

    auto release = new Semaphore(0);
    auto held = new BoundedInput(InputLimits(2, 4, 1), 3,
        (string path, ulong bytes) { release.wait(); },
        (string path, Throwable error) { assert(0, error.msg); });
    foreach (i; 0 .. 4) assert(held.submit(i.to!string, 1));
    auto during = held.snapshot();
    assert(during.peakQueuedDocuments == 2);
    assert(during.peakReservedBytes == 4);
    assert(during.peakWorkerDescriptors == 1);
    foreach (i; 0 .. 4) release.notify();
    auto drained = held.finish();
    assert(drained.succeeded == 4 && drained.reservedBytes == 0 &&
        drained.queuedDocuments == 0 && drained.workerDescriptors == 0);

    auto entered = new Semaphore(0);
    auto unblock = new Semaphore(0);
    auto capMetrics = new CoordinationMetricsV2;
    auto threadCap = new BoundedInput(InputLimits(3, 3, 3), 2,
        (string path, ulong bytes) {
            entered.notify();
            unblock.wait();
        },
        (string path, Throwable error) { assert(0, error.msg); },
        null, capMetrics);
    foreach (i; 0 .. 3) assert(threadCap.submit(i.to!string, 1));
    InputCounts joined;
    auto joiner = new Thread({ joined = threadCap.finish(); });
    joiner.start();
    entered.wait();
    entered.wait();
    Thread.sleep(20.msecs);
    assert(threadCap.snapshot().peakWorkerDescriptors == 2);
    foreach (i; 0 .. 3) unblock.notify();
    joiner.join();
    assert(joined.succeeded == 3 && joined.workerDescriptors == 0 &&
        joined.reservedBytes == 0);
    capMetrics.finishWall();
    assert(parseJSON(capMetrics.json())["limits"]
        ["worker_descriptors"].integer == 2);

    auto holdMetrics = new CoordinationMetricsV2;
    auto holdEntered = new Semaphore(0);
    auto holdRelease = new Semaphore(0);
    auto callbackCompleted = new Semaphore(0);
    auto measuredHold = new BoundedInput(InputLimits(1, 1, 1), 2,
        (string path, ulong bytes) {
            holdEntered.notify();
            holdRelease.wait();
            callbackCompleted.notify();
        },
        (string path, Throwable error) { assert(0, error.msg); },
        null, holdMetrics);
    assert(measuredHold.submit("forced descriptor release wait", 1));
    assert(holdEntered.wait(500.msecs));
    measuredHold.mutex.lock();
    holdRelease.notify();
    assert(callbackCompleted.wait(500.msecs));
    Thread.sleep(60.msecs);
    measuredHold.mutex.unlock();
    auto measuredCounts = measuredHold.finish();
    holdMetrics.finishWall();
    auto measuredJson = parseJSON(holdMetrics.json());
    assert(measuredCounts.succeeded == 1 &&
        measuredJson["phases"]["descriptor_hold"]["calls"].integer == 1 &&
        measuredJson["phases"]["descriptor_hold"]["nanoseconds"].integer >=
            50_000_000,
        "descriptor hold omitted the forced reservation-release wait");

    shared size_t faults;
    auto failing = new BoundedInput(InputLimits(2, 2, 1), 4,
        (string path, ulong bytes) { throw new Exception("injected worker fault"); },
        (string path, Throwable error) { faults.atomicOp!"+="(1); });
    foreach (i; 0 .. 32) assert(failing.submit(i.to!string, 1));
    auto failure = failing.finish();
    assert(faults.atomicLoad == 32 && failure.failed == 32);
    assert(failure.reservedBytes == 0 && failure.workerDescriptors == 0 &&
        failure.queuedDocuments == 0);

    size_t fatalReports;
    auto fatal = new BoundedInput(InputLimits(2, 2, 1), 1,
        (string path, ulong bytes) { throw new Exception("fatal worker fault"); },
        (string path, Throwable error) { ++fatalReports; },
        (Throwable error) { return true; });
    assert(fatal.submit("first", 1));
    assert(!fatal.submit("second", 1));
    auto fatalCounts = fatal.finish();
    assert(fatal.fatal() !is null && fatalReports == 1 &&
        fatalCounts.failed == 1 && fatalCounts.succeeded == 0 &&
        fatalCounts.reservedBytes == 0 && fatalCounts.workerDescriptors == 0 &&
        fatalCounts.queuedDocuments == 0);

    auto reportFault = new BoundedInput(InputLimits(1, 1, 1), 1,
        (string path, ulong bytes) { throw new Exception("document fault"); },
        (string path, Throwable error) { throw new Exception("log ack fault"); },
        (Throwable error) { return false; });
    assert(reportFault.submit("first", 1));
    assert(!reportFault.submit("second", 1));
    assert(reportFault.fatal() !is null &&
        reportFault.fatal().msg == "log ack fault" &&
        reportFault.finish().reservedBytes == 0);

    auto cancelled = new BoundedInput(InputLimits(2, 2, 1), 4,
        (string path, ulong bytes) {},
        (string path, Throwable error) { assert(0); });
    cancelled.cancel();
    assert(!cancelled.submit("cancelled", 1));
    assert(!cancelled.submit("oversized after cancellation", 3));
    auto afterCancel = cancelled.finish();
    assert(afterCancel.submitted == 0 && afterCancel.reservedBytes == 0 &&
        afterCancel.workerDescriptors == 0 && afterCancel.queuedDocuments == 0);

    BoundedInput inFlight;
    inFlight = new BoundedInput(InputLimits(1, 1, 1), 1,
        (string path, ulong bytes) { inFlight.cancel(); },
        (string path, Throwable error) { assert(0); });
    assert(inFlight.submit("active cancellation", 1));
    assert(!inFlight.submit("after cancellation", 1));
    auto afterInFlight = inFlight.finish();
    assert(afterInFlight.succeeded == 1 && afterInFlight.reservedBytes == 0 &&
        afterInFlight.queuedDocuments == 0 && afterInFlight.workerDescriptors == 0);
}
