/// Typed document-stage registrations; concrete stage modules own their registrations.
module stages.registry;

import stages.contract : ResourceDeclaration, StageDeclaration, StageTransform;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : validate;

enum OptionType { text, integer, boolean }
enum FilterPlacement { none, before, after }

/// Values have one active type; callers cannot reinterpret a parsed option.
struct StageOption {
    private OptionType optionType;
    private string textValue;
    private long integerValue;
    private bool booleanValue;

    static StageOption text(string value) {
        StageOption result;
        result.optionType = OptionType.text;
        result.textValue = value;
        return result;
    }
    static StageOption integer(long value) {
        StageOption result;
        result.optionType = OptionType.integer;
        result.integerValue = value;
        return result;
    }
    static StageOption boolean(bool value) {
        StageOption result;
        result.optionType = OptionType.boolean;
        result.booleanValue = value;
        return result;
    }
    OptionType type() const { return optionType; }
    string asText() const {
        enforce(optionType == OptionType.text, "option is not text");
        return textValue;
    }
    long asInteger() const {
        enforce(optionType == OptionType.integer, "option is not an integer");
        return integerValue;
    }
    bool asBoolean() const {
        enforce(optionType == OptionType.boolean, "option is not boolean");
        return booleanValue;
    }
}

alias StageOptions = StageOption[string];
alias StageFactory = StageTransform function(const ref StageOptions);

struct OptionDeclaration {
    string key;
    OptionType type;
    bool required;
}

/// `before` and `after` constrain relative order only when both stages occur.
struct StageRegistration {
    StageDeclaration declaration;
    OptionDeclaration[] options;
    string[] before;
    string[] after;
    StageFactory factory;
    FilterPlacement filterPlacement;
}

private void validKey(string key) {
    enforce(key.length != 0, "stage/option key must not be empty");
    validate(key);
    enforce(key.indexOf('\0') < 0, "stage/option key must not contain NUL");
}

/// An explicit registry also permits isolated validation without mutating process state.
struct StageRegistry {
    private StageRegistration[string] registrations;

    void add(StageRegistration registration) {
        auto declaration = registration.declaration;
        declaration = StageDeclaration(declaration.key, declaration.passMode,
            ResourceDeclaration(declaration.resources.cpuSlots,
                declaration.resources.memoryBytes,
                declaration.resources.exclusiveNames));
        enforce(registration.factory !is null, "stage factory is required");
        enforce(registration.filterPlacement == FilterPlacement.none ||
            registration.filterPlacement == FilterPlacement.before ||
            registration.filterPlacement == FilterPlacement.after,
            "invalid filter placement");
        enforce((declaration.key in registrations) is null,
            "duplicate stage: " ~ declaration.key);
        foreach (i, option; registration.options) {
            validKey(option.key);
            enforce(option.type == OptionType.text || option.type == OptionType.integer ||
                option.type == OptionType.boolean, "invalid option type");
            foreach (prior; registration.options[0 .. i])
                enforce(option.key != prior.key, "duplicate option: " ~ option.key);
        }
        foreach (key; registration.before) {
            validKey(key);
            enforce(key != declaration.key, "stage cannot precede itself");
            foreach (prior; registration.after)
                enforce(key != prior, "contradictory stage order: " ~ key);
        }
        foreach (key; registration.after) {
            validKey(key);
            enforce(key != declaration.key, "stage cannot follow itself");
        }
        registration.declaration = declaration;
        registration.options = registration.options.dup;
        registration.before = registration.before.dup;
        registration.after = registration.after.dup;
        registrations[declaration.key] = registration;
    }

    const(StageRegistration)* find(string key) const {
        return key in registrations;
    }

    /// Validate declared option names/types once, then invoke the factory.
    StageTransform build(string key, const StageOptions options) const {
        auto registration = find(key);
        enforce(registration !is null, "unknown stage: " ~ key);
        foreach (name, value; options) {
            const(OptionDeclaration)* declaration;
            foreach (ref candidate; registration.options)
                if (candidate.key == name) declaration = &candidate;
            enforce(declaration !is null, "unknown option for " ~ key ~ ": " ~ name);
            enforce(declaration.type == value.type,
                "option " ~ name ~ " has the wrong type for stage " ~ key);
        }
        foreach (declaration; registration.options)
            if (declaration.required)
                enforce((declaration.key in options) !is null,
                    "missing option for " ~ key ~ ": " ~ declaration.key);
        auto transform = registration.factory(options);
        enforce(transform !is null, "stage factory returned no transform: " ~ key);
        return transform;
    }

    /// Relative constraints apply to every configured occurrence. Repeated
    /// implementations are allowed; stable instance identity lives above the registry.
    void validateOrder(const string[] keys) const {
        foreach (key; keys) enforce(find(key) !is null, "unknown stage: " ~ key);
        foreach (i, key; keys) {
            auto registration = find(key);
            foreach (peer; registration.before) {
                enforce(find(peer) !is null, "unknown ordering peer: " ~ peer);
                foreach (j, configured; keys)
                    if (configured == peer)
                        enforce(i < j, "stage " ~ key ~ " must precede " ~ peer);
            }
            foreach (peer; registration.after) {
                enforce(find(peer) !is null, "unknown ordering peer: " ~ peer);
                foreach (j, configured; keys)
                    if (configured == peer)
                        enforce(j < i, "stage " ~ key ~ " must follow " ~ peer);
            }
        }
    }
}

private StageRegistry registeredStages;

/// Called by a concrete stage's own `static this()`, after importing that module.
void registerStage(StageRegistration registration) {
    registeredStages.add(registration);
}

const(StageRegistry)* availableStages() {
    return &registeredStages;
}

unittest {
    import stages.contract : PassMode, ResourceDeclaration, StageDecision, StageDocument;
    import std.exception : assertThrown;

    StageRegistry registry;
    auto factory = (const ref StageOptions options) {
        return cast(StageTransform) ((StageDocument input) {
            return StageDecision.map(input);
        });
    };
    auto item = StageRegistration(StageDeclaration("sample", PassMode.singlePass,
        ResourceDeclaration(1, 0)), [OptionDeclaration("label", OptionType.text, true)],
        null, null, factory);
    registry.add(item);
    auto found = registry.find("sample");
    assert(found !is null);
    static assert(!__traits(compiles, found.options[0].key = "bypass"));
    static assert(!__traits(compiles, found.before ~= "bypass"));
    static assert(!__traits(compiles, availableStages().add(item)));
    static assert(!__traits(compiles, *availableStages() = StageRegistry.init));
    assertThrown(registry.add(item));
    item.declaration.key = "other";
    item.options = [OptionDeclaration("x", OptionType.text),
        OptionDeclaration("x", OptionType.boolean)];
    assertThrown(registry.add(item));
    item.options = null;
    item.before = ["other"];
    assertThrown(registry.add(item));
    item.before = null;
    item.factory = null;
    assertThrown(registry.add(item));
    assert(StageOption.integer(4).asInteger() == 4);
    assert(StageOption.boolean(true).asBoolean());
    assertThrown(StageOption.text("x").asInteger());
    assert(registry.build("sample", ["label": StageOption.text("x")]) !is null);
    assertThrown(registry.build("sample", ["label": StageOption.integer(1)]));
    assertThrown(registry.build("sample", null));
    registry.validateOrder(["sample", "sample"]);
}
