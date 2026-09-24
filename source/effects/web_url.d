/// Bounded, D-owned HTTP(S) URL identity and discovery provenance.
module effects.web_url;

import crypto.sha256 : sha256Of;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : UTFException, validate;

enum string webUrlPolicy = "web-url:v1";
enum size_t maxWebUrlBytes = 4096;

enum WebUrlInput : ubyte { response, documentBase, reference }

enum WebUrlFailureReason : ubyte {
    none,
    oversized,
    invalidUtf8,
    nativeCreate,
    nativeInitialize,
    malformed,
    unsupportedScheme,
    credentials,
    serialization,
    outputLimit,
}

/// Content-free failure information. Input URL bytes never cross this boundary.
struct WebUrlFailure {
    WebUrlInput input;
    WebUrlFailureReason reason;
}

/// Canonical locator. `canonical` is the fetch identity and never has a fragment.
/// Every string is D-owned and remains valid after the native parser is destroyed.
struct WebUrl {
    private string policy_;
    private string canonical_;
    private string origin_;
    private bool hasFragment_;
    private string fragment_;

    @property string policy() const pure nothrow @safe { return policy_; }
    @property string canonical() const pure nothrow @safe { return canonical_; }
    @property string origin() const pure nothrow @safe { return origin_; }
    @property bool hasFragment() const pure nothrow @safe { return hasFragment_; }
    @property string fragment() const pure nothrow @safe { return fragment_; }

    bool sameOrigin(const WebUrl other) const pure nothrow @safe {
        return origin_ == other.origin_;
    }
}

struct WebUrlOutcome {
    private bool succeeded;
    private WebUrl value_;
    private WebUrlFailure failure_;

    bool isResolved() const pure nothrow @safe { return succeeded; }
    const(WebUrl) value() const pure {
        enforce(succeeded, "web URL outcome is rejected");
        return value_;
    }
    WebUrlFailure failure() const pure {
        enforce(!succeeded, "web URL outcome is resolved");
        return failure_;
    }
}

enum RelationKind : ubyte { hyperlink, embeddedResource }
enum AttributeKind : ubyte { href, src }

/// Provenance contains no raw attribute text. Its digest is lower-case SHA-256.
struct DiscoveryEvidence {
    WebUrl referrer;
    RelationKind relation;
    size_t nodeOrdinal;
    AttributeKind attribute;
    string rawValueDigest;
    size_t depth;
}

struct DiscoveryCandidate {
    WebUrl locator;
    DiscoveryEvidence evidence;
}

struct DiscoveryOutcome {
    private bool succeeded;
    private DiscoveryCandidate value_;
    private WebUrlFailure failure_;

    bool isDiscovered() const pure nothrow @safe { return succeeded; }
    const(DiscoveryCandidate) value() const pure {
        enforce(succeeded, "discovery outcome is rejected");
        return value_;
    }
    WebUrlFailure failure() const pure {
        enforce(!succeeded, "discovery outcome is resolved");
        return failure_;
    }
}

private extern(C) {
    struct NativeUrl { ubyte opaque; }
    struct NativeUrlParser {
        NativeUrl* url;
        void* memory;
        void* log;
        void* idna;
        ubyte* buffer;
    }

    alias SerializeCallback = int function(const(ubyte)*, size_t, void*);
    alias PartSerializer = int function(const NativeUrl*, SerializeCallback,
        void*);

    NativeUrlParser* lxb_url_parser_create();
    int lxb_url_parser_init(NativeUrlParser*, void*);
    void lxb_url_parser_clean(NativeUrlParser*);
    NativeUrlParser* lxb_url_parser_destroy(NativeUrlParser*, bool);
    void lxb_url_parser_memory_destroy(NativeUrlParser*);
    NativeUrl* lxb_url_parse(NativeUrlParser*, const NativeUrl*,
        const(ubyte)*, size_t);
    int lxb_url_serialize(const NativeUrl*, SerializeCallback, void*, bool);
    int lxb_url_serialize_scheme(const NativeUrl*, SerializeCallback, void*);
    int lxb_url_serialize_username(const NativeUrl*, SerializeCallback, void*);
    int lxb_url_serialize_password(const NativeUrl*, SerializeCallback, void*);
    size_t lexbor_plog_length_noi(void*);
}

static assert(NativeUrlParser.sizeof == 5 * (void*).sizeof);

private struct Serialized {
    string bytes;
    bool failed;
    bool oversized;
}

private extern(C) int appendSerialized(const(ubyte)* data, size_t length,
        void* context) nothrow {
    auto output = cast(Serialized*) context;
    if (data is null && length != 0) {
        output.failed = true;
        return 1;
    }
    if (length > maxWebUrlBytes - output.bytes.length) {
        output.oversized = true;
        return 1;
    }
    try {
        output.bytes ~= cast(const(char)[]) data[0 .. length];
    } catch (Throwable) {
        output.failed = true;
        return 1;
    }
    return 0;
}

private bool hasParseErrors(NativeUrlParser* parser) {
    return parser.log !is null && lexbor_plog_length_noi(parser.log) != 0;
}

private bool validInput(string input) {
    try validate(input);
    catch (UTFException) return false;
    return true;
}

private WebUrlOutcome rejected(WebUrlInput input,
        WebUrlFailureReason reason) pure nothrow {
    WebUrlOutcome outcome;
    outcome.failure_ = WebUrlFailure(input, reason);
    return outcome;
}

private NativeUrl* parseStrict(NativeUrlParser* parser, const NativeUrl* base,
        string input, WebUrlInput inputKind, ref WebUrlFailure failure) {
    if (input.length > maxWebUrlBytes) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.oversized);
        return null;
    }
    if (!validInput(input)) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.invalidUtf8);
        return null;
    }
    lxb_url_parser_clean(parser);
    auto parsed = lxb_url_parse(parser, base,
        cast(const(ubyte)*) input.ptr, input.length);
    if (parsed is null) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.malformed);
        return null;
    }
    return parsed;
}

private bool serializePart(NativeUrl* url,
        PartSerializer serializer,
        ref Serialized output) {
    const status = serializer(url, &appendSerialized, &output);
    return status == 0 && !output.failed && !output.oversized;
}

private bool hasCredentials(NativeUrl* url, ref WebUrlFailureReason reason) {
    Serialized username;
    if (!serializePart(url, &lxb_url_serialize_username, username)) {
        reason = username.oversized ? WebUrlFailureReason.outputLimit :
            WebUrlFailureReason.serialization;
        return true;
    }
    Serialized password;
    if (!serializePart(url, &lxb_url_serialize_password, password)) {
        reason = password.oversized ? WebUrlFailureReason.outputLimit :
            WebUrlFailureReason.serialization;
        return true;
    }
    if (username.bytes.length != 0 || password.bytes.length != 0) {
        reason = WebUrlFailureReason.credentials;
        return true;
    }
    return false;
}

private bool webScheme(NativeUrl* url, ref WebUrlFailureReason reason) {
    Serialized scheme;
    if (!serializePart(url, &lxb_url_serialize_scheme, scheme)) {
        reason = scheme.oversized ? WebUrlFailureReason.outputLimit :
            WebUrlFailureReason.serialization;
        return false;
    }
    if (scheme.bytes != "http" && scheme.bytes != "https") {
        reason = WebUrlFailureReason.unsupportedScheme;
        return false;
    }
    return true;
}

private bool serializeUrl(NativeUrl* url, bool excludeFragment,
        ref Serialized output) {
    const status = lxb_url_serialize(url, &appendSerialized, &output,
        excludeFragment);
    return status == 0 && !output.failed && !output.oversized;
}

private bool ownUrl(NativeUrlParser* parser, NativeUrl* native,
        WebUrlInput inputKind,
        ref WebUrl result, ref WebUrlFailure failure) {
    WebUrlFailureReason reason;
    if (hasCredentials(native, reason)) {
        failure = WebUrlFailure(inputKind, reason);
        return false;
    }
    if (hasParseErrors(parser)) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.malformed);
        return false;
    }
    if (!webScheme(native, reason)) {
        failure = WebUrlFailure(inputKind, reason);
        return false;
    }

    Serialized fetch;
    if (!serializeUrl(native, true, fetch)) {
        failure = WebUrlFailure(inputKind, fetch.oversized ?
            WebUrlFailureReason.outputLimit : WebUrlFailureReason.serialization);
        return false;
    }
    Serialized complete;
    if (!serializeUrl(native, false, complete)) {
        failure = WebUrlFailure(inputKind, complete.oversized ?
            WebUrlFailureReason.outputLimit : WebUrlFailureReason.serialization);
        return false;
    }

    const authorityStart = fetch.bytes.indexOf("://");
    if (authorityStart < 0) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.serialization);
        return false;
    }
    const pathStart = fetch.bytes.indexOf('/', cast(size_t) authorityStart + 3);
    if (pathStart < 0) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.serialization);
        return false;
    }
    if (complete.bytes.length < fetch.bytes.length ||
            complete.bytes[0 .. fetch.bytes.length] != fetch.bytes) {
        failure = WebUrlFailure(inputKind, WebUrlFailureReason.serialization);
        return false;
    }

    result.policy_ = webUrlPolicy;
    result.canonical_ = fetch.bytes.idup;
    result.origin_ = fetch.bytes[0 .. cast(size_t) pathStart].idup;
    if (complete.bytes.length != fetch.bytes.length) {
        if (complete.bytes[fetch.bytes.length] != '#') {
            failure = WebUrlFailure(inputKind, WebUrlFailureReason.serialization);
            return false;
        }
        result.hasFragment_ = true;
        result.fragment_ = complete.bytes[fetch.bytes.length + 1 .. $].idup;
    }
    return true;
}

private struct Resolution {
    bool succeeded;
    WebUrl response;
    WebUrl target;
    WebUrlFailure failure;
}

private Resolution resolveImpl(string responseUrl, string reference,
        string documentBase) {
    Resolution resolution;
    auto parser = lxb_url_parser_create();
    if (parser is null) {
        resolution.failure = WebUrlFailure(WebUrlInput.response,
            WebUrlFailureReason.nativeCreate);
        return resolution;
    }
    bool initialized;
    scope(exit) {
        if (initialized) lxb_url_parser_memory_destroy(parser);
        lxb_url_parser_destroy(parser, true);
    }
    if (lxb_url_parser_init(parser, null) != 0) {
        resolution.failure = WebUrlFailure(WebUrlInput.response,
            WebUrlFailureReason.nativeInitialize);
        return resolution;
    }
    initialized = true;

    WebUrlFailure failure;
    auto response = parseStrict(parser, null, responseUrl,
        WebUrlInput.response, failure);
    if (response is null || !ownUrl(parser, response, WebUrlInput.response,
            resolution.response, failure)) {
        resolution.failure = failure;
        return resolution;
    }

    NativeUrl* base = response;
    if (documentBase !is null) {
        auto document = parseStrict(parser, response, documentBase,
            WebUrlInput.documentBase, failure);
        WebUrl ownedDocument;
        if (document is null || !ownUrl(parser, document, WebUrlInput.documentBase,
                ownedDocument, failure)) {
            resolution.failure = failure;
            return resolution;
        }
        base = document;
    }

    auto target = parseStrict(parser, base, reference,
        WebUrlInput.reference, failure);
    if (target is null || !ownUrl(parser, target, WebUrlInput.reference,
            resolution.target, failure)) {
        resolution.failure = failure;
        return resolution;
    }
    resolution.succeeded = true;
    return resolution;
}

/// Resolve `reference` against the optional document base, itself resolved
/// against the response URL. A null base means no document base; an empty base
/// is a present base and resolves to the response URL.
WebUrlOutcome resolveWebUrl(string responseUrl, string reference,
        string documentBase = null) {
    auto resolution = resolveImpl(responseUrl, reference, documentBase);
    if (!resolution.succeeded)
        return rejected(resolution.failure.input, resolution.failure.reason);
    WebUrlOutcome outcome;
    outcome.succeeded = true;
    outcome.value_ = resolution.target;
    return outcome;
}

/// Build a candidate and content-free provenance from already-selected HTML
/// evidence. This function does not walk HTML or make admission decisions.
DiscoveryOutcome discoverWebUrl(string responseUrl, string reference,
        RelationKind relation, size_t nodeOrdinal, AttributeKind attribute,
        size_t depth, string documentBase = null) {
    auto resolution = resolveImpl(responseUrl, reference, documentBase);
    DiscoveryOutcome outcome;
    if (!resolution.succeeded) {
        outcome.failure_ = resolution.failure;
        return outcome;
    }
    outcome.succeeded = true;
    outcome.value_.locator = resolution.target;
    outcome.value_.evidence = DiscoveryEvidence(resolution.response, relation,
        nodeOrdinal, attribute,
        toHexString!(LetterCase.lower)(sha256Of(
            cast(const(ubyte)[]) reference)).idup, depth);
    return outcome;
}

unittest {
    auto resolved = resolveWebUrl("HTTPS://Example.COM:443/a/b", "../c#part");
    assert(resolved.isResolved);
    assert(resolved.value.canonical == "https://example.com/c");
    assert(resolved.value.hasFragment && resolved.value.fragment == "part");

    auto peer = resolveWebUrl("https://example.com/", "/other");
    assert(peer.isResolved && resolved.value.sameOrigin(peer.value));
    auto cross = resolveWebUrl("https://example.com/", "http://example.com/");
    assert(cross.isResolved && !resolved.value.sameOrigin(cross.value));
}
