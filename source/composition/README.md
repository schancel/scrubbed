# Composition ownership

This subtree owns pure compilation between the durable job model and runtime
registries. It performs no I/O and imports no concrete filter or stage module.

[`compiler.d`](compiler.d) validates a `JobSpec`, explicitly converts its
typed scalar options into registry-owned values, invokes injected stage and
filter factories once, validates relative implementation order, and retains
each stable stage-instance ID plus the canonical `job:v3:` identity. Compiled
identity, stage order, IDs, and declarations are exposed through read-only
views, and explicit module-private constructors suppress D's generated
aggregate initializer, so callers cannot detach executable behavior from that
identity. [`access_contract.d`](access_contract.d) pins that external-module
construction boundary at compile time.

A stage registration declares filter placement: `none`, `before`, or `after`.
Compilation rejects filters on `none`; actual before/after content application
belongs to the later execution switch. `stages.text_transform` is the initial
self-registering `before` stage and maps the document unchanged, so its
compiled filters are its only eventual content transform.

Dependency direction is `composition -> job/pipeline/stages/domain/content`.
CLI parsing, concrete registrations, effects, scheduling, mappings, sinks,
and transport remain outside this subtree.
