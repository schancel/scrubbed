# Composition ownership

This subtree owns pure compilation between the durable job model and runtime
registries. It performs no I/O and imports no concrete filter or stage module.

[`compiler.d`](compiler.d) validates a `JobSpec`, explicitly converts its
typed scalar options into registry-owned values, invokes injected stage and
filter factories once, validates relative implementation order, and retains
each stable stage-instance ID plus the canonical `job:v3:` identity. Compiled
stage and configured-filter execution retain only pure context-free function
pointers with transitive-immutable parsed configuration; factories never run
during document execution and mutable streaming state is local to each run.
Compiled identity, stage order, IDs, and declarations are exposed through
read-only
views, and explicit module-private constructors suppress D's generated
aggregate initializer, so callers cannot detach executable behavior from that
identity. [`access_contract.d`](access_contract.d) pins that external-module
construction boundary at compile time.

[`executor.d`](executor.d) runs one compiled stage over checked documents. A
nonempty filter chain is an explicit UTF-8 materialization barrier at the
declared before/after position; an empty chain preserves the original Content
object and borrowed-owner lifetime. After-filters apply only to emitted
map/split payloads, not rejection or quarantine payloads. Multi-stage job and
effects orchestration remain outside this module.

[`job_executor.d`](job_executor.d) runs one compiled linear job for one checked
source record. Only emitted events continue to the next stage; rejection and
quarantine are terminal, while split children retain order and immediate-parent
provenance through later maps or terminal decisions. It returns only final and
terminal events. An empty job is a checked no-op map. The caller still owns the
content lifetime: this pure layer performs no source fetch, sink write, owner
close, cancellation, resource reservation, or filesystem work.

A stage registration declares filter placement: `none`, `before`, or `after`.
Compilation rejects filters on `none`; actual before/after content application
belongs to the later execution switch. `stages.text_transform` is the initial
self-registering `before` stage and maps the document unchanged, so its
compiled filters are its only eventual content transform.

Dependency direction is `composition -> job/pipeline/stages/domain/content`.
CLI parsing, concrete registrations, effects, scheduling, mappings, sinks,
and transport remain outside this subtree.

[`dispatch_compiler.d`](dispatch_compiler.d) validates a complete v4 plan,
checks route/outcome compatibility against an injected finite extractor
registry, preflights every route and option before any extractor factory is
called, invokes every referenced extractor factory once, and compiles the
nested v3 common job once. Its opaque result binds canonical identity, bounded
detection/container limits, the complete action declaration, configured
routes, and the common plan.

[`dispatch_executor.d`](dispatch_executor.d) detects, refines, and selects
once. Route actions invoke one configured extractor and converge its checked
`TextDocumentV1` through the common plan without copying text payload bytes at
the boundary. Split/derived common output fails closed. Reject, quarantine,
and pass actions are terminal and skip extractor/common execution; pass keeps
the original document and `Content` object. Structured events retain source,
refined/container evidence, action, extractor identity, warnings, and
provenance, while borrowed owners remain caller-owned.
