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
/// as range pipelines internally -- the registered function is just the
/// boundary each filter presents to the chain, not a constraint on how it is
/// implemented inside. Option-aware factories parse immutable string options
/// once while the pipeline is built and return a typed configured closure.
module pipeline;

alias FilterOptions = string[string];
/// Original public filter contract, retained for source compatibility.
alias Filter = string function(string);
/// A configured stage may capture typed options parsed once at build time.
alias ConfiguredFilter = string delegate(string);
alias FilterFactory = ConfiguredFilter function(const ref FilterOptions);

struct FilterSpec {
    string name;
    FilterOptions options;
}

private struct FilterRegistration {
    Filter plain;
    FilterFactory factory;
}

private FilterRegistration[string] registry;

/// Register a filter under `name`. Call once per filter, typically from a
/// module constructor (`static this()`) in that filter's own module, so
/// registration stays next to the implementation rather than centralized
/// in one big list someone has to remember to update.
void registerFilter(string name, Filter f) {
    registry[name] = FilterRegistration(f, null);
}

/// Register an option-aware factory. It must validate and parse every option;
/// Pipeline.build calls it once and stores the returned typed closure.
void registerFilterFactory(string name, FilterFactory factory) {
    registry[name] = FilterRegistration(null, factory);
}

string[] availableFilters() {
    return registry.keys;
}

/// An ordered, resolved chain of filters, built from names against the
/// registry. Throws if any name isn't registered -- fail at pipeline
/// construction time, not partway through processing a document tree.
struct Pipeline {
    private struct Stage {
        Filter plain;
        ConfiguredFilter configured;
    }
    private Stage[] stages;
    private string[] stageNames;

    static Pipeline build(const(string)[] filterNames) {
        FilterSpec[] specs;
        foreach (name; filterNames) specs ~= FilterSpec(name);
        return buildConfigured(specs);
    }

    static Pipeline buildConfigured(FilterSpec[] specs) {
        Pipeline p;
        foreach (spec; specs) {
            auto registration = spec.name in registry;
            if (registration is null)
                throw new Exception("unknown filter: " ~ spec.name ~
                    " (available: " ~ availableFilters.idup.to!string ~ ")");
            if (registration.factory !is null) {
                p.stages ~= Stage(null, registration.factory(spec.options));
            } else {
                if (spec.options.length)
                    throw new Exception("filter '" ~ spec.name ~ "' accepts no options");
                p.stages ~= Stage(registration.plain, null);
            }
            p.stageNames ~= spec.name;
        }
        return p;
    }

    string run(string text) const {
        foreach (stage; stages) {
            if (stage.configured !is null)
                text = stage.configured(text);
            else
                text = stage.plain(text);
        }
        return text;
    }

    const(string)[] names() const {
        return stageNames;
    }
}

import std.conv : to;

private string legacyFilterTest(string text) { return text ~ "!"; }

unittest {
    Filter typedLegacy = &legacyFilterTest;
    auto registrar = &registerFilter;
    registrar("__legacy-filter-test", typedLegacy);
    assert(Pipeline.build(["__legacy-filter-test"]).run("ok") == "ok!");
    assert(Pipeline.build([]).names.length == 0);
    assert(Pipeline.build(null).names.length == 0);
}
