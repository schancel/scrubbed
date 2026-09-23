/// Bounded, local-only admission for the CLI's file walk.
module effects.bounded_input;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
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

    this(InputLimits limits, size_t threads,
         void delegate(string, ulong) process,
         void delegate(string, Throwable) reportFailure,
         bool delegate(Throwable) isFatal = null) {
        if (!limits.queuedDocuments || !limits.reservedBytes ||
            !limits.workerDescriptors || !threads)
            throw new Exception("input limits and threads must be positive");
        this.limits = limits;
        this.process = process;
        this.reportFailure = reportFailure;
        this.isFatal = isFatal;
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

        if (pool is null) {
            execute(path, bytes, sequence);
        } else {
            try {
                auto work = task!executeTask(this, path, bytes, sequence);
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
            size_t sequence) {
        self.execute(path, bytes, sequence);
    }

    private void execute(string path, ulong bytes, size_t sequence) {
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
        if (pool !is null) pool.finish(true);
        mutex.lock();
        auto result = counts;
        mutex.unlock();
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
    auto threadCap = new BoundedInput(InputLimits(3, 3, 3), 2,
        (string path, ulong bytes) {
            entered.notify();
            unblock.wait();
        },
        (string path, Throwable error) { assert(0, error.msg); });
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
