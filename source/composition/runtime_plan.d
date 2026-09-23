/// Closed shipping runtime plan: unchanged linear v3 or explicit dispatch v4.
module composition.runtime_plan;

import composition.compiler : CompiledJob;
import composition.dispatch_compiler : CompiledDispatchJobV1;
import composition.dispatch_executor : DispatchExecutionEventV1,
    DispatchEventKindV1, runDispatchJobV1;
import composition.job_executor : runCompiledJob;
import stages.contract : EventKind, StageDocument, StageEvent;
import std.exception : enforce;

enum RuntimePlanKindV1 : ubyte { linearV3, dispatchV4 }

struct RuntimeExecutionV1 {
    StageEvent[] events;
    bool hasDispatch;
    DispatchExecutionEventV1 dispatch;
}

struct RuntimePlanV1 {
private:
    bool initialized;
    RuntimePlanKindV1 kindValue;
    final class LinearHolder { CompiledJob value; this(CompiledJob value) { this.value = value; } }
    final class DispatchHolder { CompiledDispatchJobV1 value; this(CompiledDispatchJobV1 value) { this.value = value; } }
    LinearHolder linearValue;
    DispatchHolder dispatchValue;
    string canonicalValue;
public:
    static RuntimePlanV1 linearV3(CompiledJob plan, string canonical) {
        plan.identity;
        RuntimePlanV1 result;
        result.initialized = true;
        result.kindValue = RuntimePlanKindV1.linearV3;
        result.linearValue = new LinearHolder(plan);
        result.canonicalValue = canonical.idup;
        enforce(result.canonicalValue.length, "runtime plan needs canonical bytes");
        return result;
    }

    static RuntimePlanV1 dispatchV4(CompiledDispatchJobV1 plan,
            string canonical) {
        plan.identity;
        RuntimePlanV1 result;
        result.initialized = true;
        result.kindValue = RuntimePlanKindV1.dispatchV4;
        result.dispatchValue = new DispatchHolder(plan);
        result.canonicalValue = canonical.idup;
        enforce(result.canonicalValue.length, "runtime plan needs canonical bytes");
        return result;
    }

    private void requireInitialized() const {
        enforce(initialized, "runtime plan is not initialized");
    }
    RuntimePlanKindV1 kind() const { requireInitialized; return kindValue; }
    bool isDispatch() const { return kind == RuntimePlanKindV1.dispatchV4; }
    string identity() {
        requireInitialized;
        return kindValue == RuntimePlanKindV1.linearV3
            ? linearValue.value.identity : dispatchValue.value.identity;
    }
    string canonical() const { requireInitialized; return canonicalValue; }
    CompiledJob linear() {
        enforce(kind == RuntimePlanKindV1.linearV3, "runtime plan is not v3");
        return linearValue.value;
    }
    CompiledDispatchJobV1 dispatch() {
        enforce(kind == RuntimePlanKindV1.dispatchV4, "runtime plan is not v4");
        return dispatchValue.value;
    }
}

RuntimeExecutionV1 runRuntimePlanV1(StageDocument input,
        ref RuntimePlanV1 plan, string declaredMediaType = null,
        string fileName = null) {
    RuntimeExecutionV1 result;
    if (plan.kind == RuntimePlanKindV1.linearV3) {
        auto linear = plan.linear;
        result.events = runCompiledJob(input, linear);
        return result;
    }
    auto dispatch = plan.dispatch;
    result.dispatch = runDispatchJobV1(input, dispatch,
        declaredMediaType, fileName);
    result.hasDispatch = true;
    auto event = result.dispatch;
    final switch (event.kind) {
    case DispatchEventKindV1.emitted:
    case DispatchEventKindV1.passed:
        result.events = [StageEvent(EventKind.emitted, event.output)];
        break;
    case DispatchEventKindV1.rejected:
        result.events = [StageEvent(EventKind.rejected, event.source,
            event.reason)];
        break;
    case DispatchEventKindV1.quarantined:
        result.events = [StageEvent(EventKind.quarantined, event.source,
            event.reason)];
        break;
    }
    enforce(result.events.length == 1 && !result.events[0].isChild,
        "dispatch runtime must produce exactly one root decision");
    return result;
}
