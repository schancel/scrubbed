/// Finite injected extractor registry and configured pure extraction port.
module extraction.port;

import content.pieces : Content, ContentPiece;
import domain.document : Document;
import extraction.container : AdmittedZipV1;
import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    TextDocumentV1, isConcreteMediaV1;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : validate;

enum ExtractorOptionTypeV1 : ubyte { text, integer, boolean }

struct ExtractorOptionV1 {
    private ExtractorOptionTypeV1 typeValue;
    private string textValue;
    private long integerValue;
    private bool booleanValue;
    static ExtractorOptionV1 text(string value) {
        validate(value); enforce(value.indexOf('\0') < 0, "extractor option contains NUL");
        ExtractorOptionV1 result; result.typeValue = ExtractorOptionTypeV1.text;
        result.textValue = value.idup; return result;
    }
    static ExtractorOptionV1 integer(long value) {
        ExtractorOptionV1 result; result.typeValue = ExtractorOptionTypeV1.integer;
        result.integerValue = value; return result;
    }
    static ExtractorOptionV1 boolean(bool value) {
        ExtractorOptionV1 result; result.typeValue = ExtractorOptionTypeV1.boolean;
        result.booleanValue = value; return result;
    }
    ExtractorOptionTypeV1 type() const pure { return typeValue; }
    string asText() const { enforce(typeValue == ExtractorOptionTypeV1.text); return textValue; }
    long asInteger() const { enforce(typeValue == ExtractorOptionTypeV1.integer); return integerValue; }
    bool asBoolean() const { enforce(typeValue == ExtractorOptionTypeV1.boolean); return booleanValue; }
}

alias ExtractorOptionsV1 = ExtractorOptionV1[string];

struct ExtractorOptionDeclarationV1 {
    string key;
    ExtractorOptionTypeV1 type;
    bool required;
    this(string key, ExtractorOptionTypeV1 type, bool required) {
        validateKey(key, "extractor option key");
        enforce(type >= ExtractorOptionTypeV1.min && type <= ExtractorOptionTypeV1.max,
            "invalid extractor option type");
        this.key = key.idup; this.type = type; this.required = required;
    }
}

/// Fixed descriptive resources; compilation does not reserve them.
struct ExtractorResourcesV1 {
    uint cpuSlots;
    size_t memoryBytes;
    this(uint cpuSlots, size_t memoryBytes) {
        enforce(cpuSlots > 0, "extractor needs at least one CPU slot");
        this.cpuSlots = cpuSlots; this.memoryBytes = memoryBytes;
    }
}

/// Descriptor snapshot exposing checked reads but no mutation API.
struct SourceContentV1 {
private:
    ContentPiece[] descriptors;
    this(Content source) {
        enforce(source !is null, "extractor source content is required");
        foreach (offset, piece; source) descriptors ~= piece;
    }
public:
    static SourceContentV1 from(Content source) {
        return SourceContentV1(source);
    }
    size_t size() const pure {
        size_t total;
        foreach (piece; descriptors) {
            auto count = piece.size;
            enforce(count <= size_t.max - total, "extractor source length overflow");
            total += count;
        }
        return total;
    }
    void stream(scope void delegate(const(ubyte)[]) pure sink,
            size_t chunkSize = 8192) const pure {
        enforce(chunkSize > 0, "extractor stream chunk size must be positive");
        auto buffer = new ubyte[chunkSize];
        size_t filled;
        foreach (piece; descriptors) {
            auto pieceSize = piece.size;
            size_t copied;
            while (copied < pieceSize) {
                auto available = chunkSize - filled;
                auto remaining = pieceSize - copied;
                auto count = available < remaining ? available : remaining;
                piece.copyTo(copied, buffer[filled .. filled + count]);
                copied += count;
                filled += count;
                if (filled == chunkSize) { sink(buffer[]); filled = 0; }
            }
        }
        if (filled) sink(buffer[0 .. filled]);
    }
}

struct ExtractionInputV1 {
    Document document;
    SourceContentV1 source;
    DetectionResultV1 detection;
    string routeName;
    AdmittedZipV1 admittedZip;
}

abstract class ExtractorConfigurationV1 {}
alias ExtractorApplyV1 = TextDocumentV1 function(ExtractionInputV1,
    immutable(ExtractorConfigurationV1)) pure;

struct ConfiguredExtractorV1 {
private:
    ExtractorApplyV1 applyValue;
    immutable(ExtractorConfigurationV1) configurationValue;
public:
    this(ExtractorApplyV1 apply,
            immutable(ExtractorConfigurationV1) configuration = null) {
        enforce(apply !is null, "configured extractor needs an apply function");
        applyValue = apply; configurationValue = configuration;
    }
    TextDocumentV1 opCall(ExtractionInputV1 input) const pure {
        enforce(applyValue !is null, "configured extractor is not initialized");
        return applyValue(input, configurationValue);
    }
    bool isValid() const pure { return applyValue !is null; }
}

alias ExtractorFactoryV1 = ConfiguredExtractorV1 function(
    const ref ExtractorOptionsV1 options);

struct ExtractorRegistrationV1 {
    string implementation;
    string version_;
    DetectionOutcomeV1[] acceptedOutcomes;
    ExtractorResourcesV1 resources;
    ExtractorOptionDeclarationV1[] optionSchema;
    ExtractorFactoryV1 factory;

    this(string implementation, string version_,
            DetectionOutcomeV1[] acceptedOutcomes,
            ExtractorResourcesV1 resources,
            ExtractorOptionDeclarationV1[] optionSchema,
            ExtractorFactoryV1 factory) {
        validateKey(implementation, "extractor implementation");
        validateLabel(version_, "extractor version");
        enforce(acceptedOutcomes.length > 0, "extractor needs accepted outcomes");
        bool[cast(size_t) DetectionOutcomeV1.max + 1] seen;
        foreach (outcome; acceptedOutcomes) {
            enforce(isConcreteMediaV1(outcome), "extractor accepts only concrete media");
            enforce(!seen[cast(size_t) outcome], "duplicate extractor outcome");
            seen[cast(size_t) outcome] = true;
        }
        bool[string] optionKeys;
        ExtractorOptionDeclarationV1[] checkedSchema;
        foreach (declaration; optionSchema) {
            auto checked = ExtractorOptionDeclarationV1(declaration.key,
                declaration.type, declaration.required);
            enforce((checked.key in optionKeys) is null,
                "duplicate extractor option declaration");
            optionKeys[checked.key] = true;
            checkedSchema ~= checked;
        }
        enforce(factory !is null, "extractor factory is required");
        this.implementation = implementation.idup;
        this.version_ = version_.idup;
        this.acceptedOutcomes = acceptedOutcomes.dup;
        this.resources = ExtractorResourcesV1(resources.cpuSlots, resources.memoryBytes);
        this.optionSchema = checkedSchema;
        this.factory = factory;
    }

    bool accepts(DetectionOutcomeV1 outcome) const pure {
        foreach (accepted; acceptedOutcomes) if (accepted == outcome) return true;
        return false;
    }

    ExtractorRegistrationV1 validatedCopy() {
        return ExtractorRegistrationV1(implementation, version_,
            acceptedOutcomes, resources, optionSchema, factory);
    }

    void validateOptions(const ref ExtractorOptionsV1 options) {
        auto checked = validatedCopy;
        checked.validateCheckedOptions(options);
    }

    private void validateCheckedOptions(const ref ExtractorOptionsV1 options) {
        enforce(options.length <= optionSchema.length,
            "extractor has undeclared options");
        foreach (key, value; options) {
            const(ExtractorOptionDeclarationV1)* found;
            foreach (ref declaration; optionSchema)
                if (declaration.key == key) found = &declaration;
            enforce(found !is null, "unknown extractor option: " ~ key);
            enforce(found.type == value.type, "wrong extractor option type: " ~ key);
        }
        foreach (declaration; optionSchema)
            enforce(!declaration.required || (declaration.key in options) !is null,
                "missing extractor option: " ~ declaration.key);
    }

    ConfiguredExtractorV1 build(const ref ExtractorOptionsV1 options) {
        auto checked = validatedCopy;
        checked.validateCheckedOptions(options);
        auto configured = checked.factory(options);
        enforce(configured.isValid, "extractor factory returned invalid configuration");
        return configured;
    }
}

/// Explicit registry only: no globals, discovery, dynamic loading or adapters.
struct ExtractorRegistryV1 {
private:
    ExtractorRegistrationV1[string] registrations;
public:
    void add(ExtractorRegistrationV1 registration) {
        enforce((registration.implementation in registrations) is null,
            "duplicate extractor registration: " ~ registration.implementation);
        registrations[registration.implementation] = registration;
    }
    const(ExtractorRegistrationV1)* find(string implementation) const {
        return implementation in registrations;
    }
    ExtractorRegistrationV1* find(string implementation) {
        return implementation in registrations;
    }
    ExtractorRegistrationV1 validated(string implementation) {
        auto registration = implementation in registrations;
        enforce(registration !is null, "unknown extractor: " ~ implementation);
        auto checked = registration.validatedCopy;
        enforce(checked.implementation == implementation,
            "extractor registry key/implementation mismatch: " ~ implementation);
        return checked;
    }
}

private void validateKey(string value, string field) {
    enforce(value.length > 0 && value.length <= 128, field ~ " is not bounded");
    foreach (index, ch; value) {
        auto base = ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9';
        enforce(index == 0 ? base : base || ch == '-' || ch == '_' || ch == '.',
            field ~ " is not canonical");
    }
}

private void validateLabel(string value, string field) {
    enforce(value.length > 0 && value.length <= 128, field ~ " is not bounded");
    validate(value); enforce(value.indexOf('\0') < 0, field ~ " contains NUL");
}

version (unittest) {
    private __gshared size_t forbiddenExtractorGlobal;
    private TextDocumentV1 impureExtractor(ExtractionInputV1 input,
            immutable(ExtractorConfigurationV1)) {
        ++forbiddenExtractorGlobal;
        return TextDocumentV1.init;
    }
}

unittest {
    static assert(!__traits(compiles, {
        ExtractionInputV1 input;
        input.source.replace(0, 0);
    }));
    static assert(!__traits(compiles, {
        ExtractorApplyV1 apply = &impureExtractor;
    }));
}
