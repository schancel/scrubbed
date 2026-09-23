/// Pure compilation of strict v4 dispatch plans through injected registries.
module composition.dispatch_compiler;

import composition.compiler : CompiledJob, compileJob;
import extraction.container : ZipInspectionLimitsV1;
import extraction.contracts : DetectionOutcomeV1, RouteActionKindV1,
    RouteActionV1, RouteDeclarationV1, RouteRuleV1;
import extraction.detector : DetectionLimitsV1;
import extraction.port : ConfiguredExtractorV1, ExtractorOptionV1,
    ExtractorOptionsV1, ExtractorOptionTypeV1, ExtractorRegistryV1,
    ExtractorRegistrationV1, ExtractorResourcesV1;
import job.dispatch_json : dispatchJobIdentityV1;
import job.dispatch_spec : DispatchActionKindV1, DispatchJobSpecV1,
    DispatchOutcomeV1, validateDispatchJobSpecV1;
import job.spec : JobOptionType;
import pipeline : FilterRegistry;
import stages.registry : StageRegistry;
import std.exception : enforce;

final class DispatchCompilationFailureV1 : Exception {
    string jobIdentity;
    DetectionOutcomeV1 outcome;
    string routeName;
    string phase;
    Exception original;
    this(string identity, DetectionOutcomeV1 outcome, string route,
            string phase, Exception original) {
        super("dispatch job " ~ identity ~ " phase " ~ phase ~ " failed: " ~
            original.msg);
        jobIdentity = identity.idup; this.outcome = outcome;
        routeName = route.idup; this.phase = phase.idup; this.original = original;
    }
}

private struct ValidatedDispatchRouteV1 {
    string name;
    ExtractorRegistrationV1 registration;
    ExtractorOptionsV1 options;
    DetectionOutcomeV1 routedOutcome;
}

struct CompiledDispatchRouteV1 {
private:
    bool initialized;
    string routeNameValue;
    string implementationValue;
    string versionValue;
    DetectionOutcomeV1[] outcomesValue;
    ExtractorResourcesV1 resourcesValue;
    ConfiguredExtractorV1 configuredValue;
    @disable this();
    this(string routeName, string implementation, string version_,
            const(DetectionOutcomeV1)[] outcomes, const ref ExtractorResourcesV1 resources,
            ConfiguredExtractorV1 configured) {
        initialized = true; routeNameValue = routeName.idup;
        implementationValue = implementation.idup; versionValue = version_.idup;
        foreach (outcome; outcomes) outcomesValue ~= outcome;
        resourcesValue = ExtractorResourcesV1(resources.cpuSlots, resources.memoryBytes);
        configuredValue = configured;
    }
    void requireCompiled() const { enforce(initialized, "dispatch route is not compiled"); }
public:
    string name() { requireCompiled; return routeNameValue; }
    string implementation() { requireCompiled; return implementationValue; }
    string version_() { requireCompiled; return versionValue; }
    const(DetectionOutcomeV1)[] acceptedOutcomes() { requireCompiled; return outcomesValue; }
    ExtractorResourcesV1 resources() { requireCompiled; return resourcesValue; }
    ConfiguredExtractorV1 configured() { requireCompiled; return configuredValue; }
    bool accepts(DetectionOutcomeV1 outcome) {
        requireCompiled; foreach (accepted; outcomesValue) if (accepted == outcome) return true;
        return false;
    }
}

struct CompiledDispatchJobV1 {
private:
    bool initialized;
    string identityValue;
    DetectionLimitsV1 detectionLimitsValue;
    ZipInspectionLimitsV1 zipLimitsValue;
    RouteDeclarationV1 declarationValue;
    CompiledDispatchRouteV1[] routesValue;
    CompiledJob commonValue;
    @disable this();
    this(string identity, DetectionLimitsV1 detectionLimits,
            ZipInspectionLimitsV1 zipLimits, RouteDeclarationV1 declaration,
            CompiledDispatchRouteV1[] routes, CompiledJob common) {
        initialized = true; identityValue = identity.idup;
        detectionLimitsValue = detectionLimits; zipLimitsValue = zipLimits;
        declarationValue = declaration; routesValue = routes.dup; commonValue = common;
    }
    void requireCompiled() const { enforce(initialized, "dispatch job is not compiled"); }
public:
    string identity() { requireCompiled; return identityValue; }
    DetectionLimitsV1 detectionLimits() { requireCompiled; return detectionLimitsValue; }
    ZipInspectionLimitsV1 zipLimits() { requireCompiled; return zipLimitsValue; }
    RouteDeclarationV1 declaration() { requireCompiled; return declarationValue; }
    const(CompiledDispatchRouteV1)[] routes() { requireCompiled; return routesValue; }
    CompiledJob common() { requireCompiled; return commonValue; }
    CompiledDispatchRouteV1 routeFor(string name) {
        requireCompiled; foreach (route; routesValue) if (route.name == name) return route;
        enforce(false, "compiled dispatch route is missing: " ~ name);
        assert(false);
    }
}

CompiledDispatchJobV1 compileDispatchJobV1(ref DispatchJobSpecV1 spec,
        ExtractorRegistryV1* extractors,
        const(StageRegistry)* stages = null,
        const(FilterRegistry)* filters = null) {
    validateDispatchJobSpecV1(spec);
    enforce(extractors !is null, "dispatch compilation needs an extractor registry");
    auto detectionLimits = DetectionLimitsV1(spec.dispatch.detector.prefixBytes,
        spec.dispatch.detector.evidenceRecords, spec.dispatch.detector.warnings);
    ZipInspectionLimitsV1 zipLimits;
    zipLimits.maxPhysicalBytes = spec.dispatch.container.maxPhysicalBytes;
    zipLimits.maxExpandedBytes = spec.dispatch.container.maxExpandedBytes;
    zipLimits.maxEntries = spec.dispatch.container.maxEntries;
    zipLimits.maxDepth = spec.dispatch.container.maxDepth;
    zipLimits.maxRatio = spec.dispatch.container.maxRatio;
    zipLimits.validate;
    auto identity = dispatchJobIdentityV1(spec);

    RouteRuleV1[] rules;
    foreach (action; spec.dispatch.actions) {
        auto outcome = extractionOutcome(action.outcome);
        RouteActionV1 compiledAction;
        final switch (action.kind) {
        case DispatchActionKindV1.route: compiledAction = RouteActionV1.route(action.target); break;
        case DispatchActionKindV1.reject: compiledAction = RouteActionV1.reject(action.target); break;
        case DispatchActionKindV1.quarantine: compiledAction = RouteActionV1.quarantine(action.target); break;
        case DispatchActionKindV1.passThrough: compiledAction = RouteActionV1.passThrough(action.target); break;
        }
        rules ~= RouteRuleV1(outcome, compiledAction);
    }
    auto declaration = RouteDeclarationV1(rules);

    // Preflight the entire finite registry boundary before invoking any
    // extractor factory. Later invalid routes cannot leave earlier effects.
    ValidatedDispatchRouteV1[] validatedRoutes;
    foreach (route; spec.dispatch.routes) {
        auto registration = extractors.find(route.extractor);
        enforce(registration !is null, "unknown extractor: " ~ route.extractor);
        auto checkedRegistration = registration.validatedCopy;
        foreach (action; spec.dispatch.actions)
            if (action.kind == DispatchActionKindV1.route && action.target == route.name)
                enforce(checkedRegistration.accepts(extractionOutcome(action.outcome)),
                    "extractor is incompatible with routed outcome: " ~ route.name);
        ExtractorOptionsV1 options;
        foreach (key, value; route.options) {
            final switch (value.type) {
            case JobOptionType.text: options[key] = ExtractorOptionV1.text(value.asText); break;
            case JobOptionType.integer: options[key] = ExtractorOptionV1.integer(value.asInteger); break;
            case JobOptionType.boolean: options[key] = ExtractorOptionV1.boolean(value.asBoolean); break;
            }
        }
        DetectionOutcomeV1 routedOutcome = DetectionOutcomeV1.unknown;
        foreach (action; spec.dispatch.actions)
            if (action.kind == DispatchActionKindV1.route && action.target == route.name) {
                routedOutcome = extractionOutcome(action.outcome);
                break;
            }
        checkedRegistration.validateOptions(options);
        validatedRoutes ~= ValidatedDispatchRouteV1(route.name.idup,
            checkedRegistration, options, routedOutcome);
    }

    CompiledDispatchRouteV1[] routes;
    foreach (validated; validatedRoutes) {
        auto configured = buildExtractor(validated.registration,
            validated.options, identity, validated.routedOutcome,
            validated.name);
        routes ~= CompiledDispatchRouteV1(validated.name,
            validated.registration.implementation,
            validated.registration.version_,
            validated.registration.acceptedOutcomes,
            validated.registration.resources, configured);
    }
    // Exactly one compilation of the nested existing v3 common plan.
    auto common = buildCommon(spec, stages, filters, identity);
    return CompiledDispatchJobV1(identity, detectionLimits,
        zipLimits, declaration, routes, common);
}

private ConfiguredExtractorV1 buildExtractor(
        ref ExtractorRegistrationV1 registration,
        const ref ExtractorOptionsV1 options, string identity,
        DetectionOutcomeV1 outcome, string route) {
    try return registration.build(options);
    catch (Exception error)
        throw new DispatchCompilationFailureV1(identity, outcome, route,
            "factory", error);
}

private CompiledJob buildCommon(ref DispatchJobSpecV1 spec,
        const(StageRegistry)* stages, const(FilterRegistry)* filters,
        string identity) {
    try return compileJob(spec.common, stages, filters);
    catch (Exception error)
        throw new DispatchCompilationFailureV1(identity,
            DetectionOutcomeV1.unknown, null, "common-compile", error);
}

private DetectionOutcomeV1 extractionOutcome(DispatchOutcomeV1 outcome) pure {
    static assert(cast(size_t) DispatchOutcomeV1.max ==
        cast(size_t) DetectionOutcomeV1.max);
    return cast(DetectionOutcomeV1) outcome;
}
