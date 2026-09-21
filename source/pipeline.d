/// Pluggable filter pipeline: filters are named, registered once, and
/// composed at runtime from config (CLI flags or a config file) rather
/// than hardcoded into a fixed chain -- so adding a new filter (an
/// HTML->Markdown converter, a different encoding fixer, a whitespace
/// normalizer with different rules) never means editing the orchestration
/// code, only registering the new filter and naming it in the chain.
///
/// A `Filter` is intentionally just `string -> string`, not a lazy range
/// transform, for filters whose algorithm genuinely needs whole-buffer
/// context (mojibake repair has to see the whole string to score
/// candidates). Filters that CAN be true zero-allocation streaming
/// transforms (e.g. control-character stripping) should still be written
/// as range pipelines internally -- `Filter.apply` is just the boundary
/// each filter presents to the chain, not a constraint on how it's
/// implemented inside.
module pipeline;

alias Filter = string function(string);

private Filter[string] registry;

/// Register a filter under `name`. Call once per filter, typically from a
/// module constructor (`static this()`) in that filter's own module, so
/// registration stays next to the implementation rather than centralized
/// in one big list someone has to remember to update.
void registerFilter(string name, Filter f) {
    registry[name] = f;
}

string[] availableFilters() {
    return registry.keys;
}

/// An ordered, resolved chain of filters, built from names against the
/// registry. Throws if any name isn't registered -- fail at pipeline
/// construction time, not partway through processing a document tree.
struct Pipeline {
    private Filter[] stages;
    private string[] stageNames;

    static Pipeline build(const(string)[] filterNames) {
        Pipeline p;
        foreach (name; filterNames) {
            auto f = name in registry;
            if (f is null)
                throw new Exception("unknown filter: " ~ name ~
                    " (available: " ~ availableFilters.idup.to!string ~ ")");
            p.stages ~= *f;
            p.stageNames ~= name;
        }
        return p;
    }

    string run(string text) const {
        foreach (stage; stages)
            text = stage(text);
        return text;
    }

    const(string)[] names() const {
        return stageNames;
    }
}

import std.conv : to;
