/// Pure AWS Signature Version 4 (SigV4) request signing, built on the
/// existing `crypto.sha256`/`crypto.hmac_sha256` primitives.
///
/// EVALUATION-ONLY module for issue #46 (S01 S3 client/capability decision).
/// It lives under experiments/, not source/, because #46 has not decided
/// whether a pure-D S3 client is adopted; see docs/sigv4-evaluation.md for
/// the verification evidence and honest verdict. Not wired into
/// effects.http_fetch/effects.curl_ffi or any production module. No network
/// I/O, no AWS account, no real credentials.
module sigv4;

import crypto.hmac_sha256 : hmacSha256;
import crypto.sha256 : sha256Of;
import std.algorithm.sorting : sort;
import std.algorithm.iteration : map;
import std.array : appender, array, join, split;
import std.string : indexOf, strip, toLower;

/// A single request header, exactly as it will be transmitted (before
/// SigV4's own lowercasing/trimming/merging rules are applied).
struct Header {
    string name;
    string value;
}

private string hexOf(scope const(ubyte)[] bytes) pure {
    static immutable char[16] digits = "0123456789abcdef";
    auto result = new char[bytes.length * 2];
    foreach (i, b; bytes) {
        result[i * 2] = digits[b >> 4];
        result[i * 2 + 1] = digits[b & 0xf];
    }
    return cast(string) result;
}

/// SHA256(data), hex-encoded -- used both for the payload hash in the
/// canonical request and for hashing the canonical request itself.
string sha256Hex(scope const(ubyte)[] data) pure {
    return hexOf(sha256Of(data));
}

private bool isUnreserved(char c) pure {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
}

/// URI-encodes every byte except the unreserved set, per SigV4's UriEncode()
/// (uppercase hex, '%' escapes, space -> %20 not '+').
string uriEncode(string value) pure {
    auto result = appender!string;
    foreach (immutable ubyte b; cast(const(ubyte)[]) value) {
        if (b < 0x80 && isUnreserved(cast(char) b)) {
            result ~= cast(char) b;
        } else {
            static immutable char[16] digits = "0123456789ABCDEF";
            result ~= '%';
            result ~= digits[b >> 4];
            result ~= digits[b & 0xf];
        }
    }
    return result.data;
}

/// Canonical URI: each '/'-delimited path segment URI-encoded individually,
/// '/' itself never encoded. Empty path becomes "/".
string canonicalUri(string rawPath) pure {
    if (rawPath.length == 0) return "/";
    auto segments = rawPath.split("/");
    auto encoded = segments.map!(s => uriEncode(s)).array;
    return encoded.join("/");
}

/// Canonical query string: each "key=value" pair (from a raw, un-decoded
/// query string) URI-encoded key/value-wise, then sorted by encoded key,
/// then by encoded value.
string canonicalQueryString(string rawQuery) pure {
    if (rawQuery.length == 0) return "";
    struct Kv { string k; string v; }
    Kv[] pairs;
    foreach (part; rawQuery.split("&")) {
        auto eq = part.indexOf('=');
        if (eq < 0) pairs ~= Kv(uriEncode(part), "");
        else pairs ~= Kv(uriEncode(part[0 .. eq]), uriEncode(part[eq + 1 .. $]));
    }
    pairs.sort!((a, b) => a.k != b.k ? a.k < b.k : a.v < b.v);
    return pairs.map!(kv => kv.k ~ "=" ~ kv.v).join("&");
}

private string trimHeaderValue(string raw) pure {
    auto trimmed = raw.strip;
    auto result = appender!string;
    bool lastWasSpace = false;
    foreach (c; trimmed) {
        if (c == ' ' || c == '\t') {
            if (!lastWasSpace) result ~= ' ';
            lastWasSpace = true;
        } else {
            result ~= c;
            lastWasSpace = false;
        }
    }
    return result.data;
}

struct CanonicalHeaders {
    string headerBlock;   // "name:value\n" for each header, sorted, trailing \n included
    string signedHeaders; // ';'-joined sorted lowercase header names
}

/// Lowercases names, trims/collapses values, merges duplicate header names by
/// joining their values with ',' in original encounter order, then sorts by
/// header name.
CanonicalHeaders canonicalizeHeaders(scope const(Header)[] headers) pure {
    string[string] merged;
    string[] order;
    foreach (h; headers) {
        auto name = h.name.toLower;
        auto value = trimHeaderValue(h.value);
        if (auto existing = name in merged) *existing = *existing ~ "," ~ value;
        else { merged[name] = value; order ~= name; }
    }
    auto names = order.dup;
    names.sort();
    auto block = appender!string;
    foreach (name; names) {
        block ~= name;
        block ~= ':';
        block ~= merged[name];
        block ~= '\n';
    }
    return CanonicalHeaders(block.data, names.join(";"));
}

/// Full input to a single SigV4 signing operation.
struct SigningInput {
    string method;
    string rawPath;             // e.g. "/", leading '/', not URI-encoded
    string rawQuery;             // without leading '?'; "" if none
    const(Header)[] headers;     // must include Host and (for this evaluation) X-Amz-Date
    const(ubyte)[] payload;      // raw body bytes; empty for GET
    string accessKeyId;
    string secretAccessKey;
    string amzDate;               // e.g. "20150830T123600Z"
    string dateStamp;             // e.g. "20150830"
    string region;
    string service;
}

struct SignedRequest {
    string canonicalRequest;
    string stringToSign;
    string credentialScope;
    string signatureHex;
    string authorizationHeader;
}

private ubyte[32] hmac(scope const(ubyte)[] key, string message) pure {
    return hmacSha256(key, cast(const(ubyte)[]) message);
}

/// The four-step SigV4 signing-key derivation:
///   kDate    = HMAC("AWS4" + secretKey, dateStamp)
///   kRegion  = HMAC(kDate, region)
///   kService = HMAC(kRegion, service)
///   kSigning = HMAC(kService, "aws4_request")
ubyte[32] deriveSigningKey(string secretAccessKey, string dateStamp, string region, string service) pure {
    auto kDate = hmac(cast(const(ubyte)[])("AWS4" ~ secretAccessKey), dateStamp);
    auto kRegion = hmac(kDate[], region);
    auto kService = hmac(kRegion[], service);
    auto kSigning = hmac(kService[], "aws4_request");
    return kSigning;
}

/// Builds the canonical request, string-to-sign, derives the signing key and
/// computes the final signature/Authorization header for one request.
SignedRequest signRequest(SigningInput input) pure {
    auto payloadHash = sha256Hex(input.payload);
    auto uri = canonicalUri(input.rawPath);
    auto query = canonicalQueryString(input.rawQuery);
    auto headersResult = canonicalizeHeaders(input.headers);

    auto canonicalRequest = input.method ~ "\n" ~ uri ~ "\n" ~ query ~ "\n" ~
        headersResult.headerBlock ~ "\n" ~ headersResult.signedHeaders ~ "\n" ~ payloadHash;

    auto credentialScope = input.dateStamp ~ "/" ~ input.region ~ "/" ~ input.service ~ "/aws4_request";
    auto stringToSign = "AWS4-HMAC-SHA256\n" ~ input.amzDate ~ "\n" ~ credentialScope ~ "\n" ~
        sha256Hex(cast(const(ubyte)[]) canonicalRequest);

    auto signingKey = deriveSigningKey(input.secretAccessKey, input.dateStamp, input.region, input.service);
    auto signatureHex = hexOf(hmac(signingKey[], stringToSign));

    auto authorizationHeader = "AWS4-HMAC-SHA256 Credential=" ~ input.accessKeyId ~ "/" ~ credentialScope ~
        ", SignedHeaders=" ~ headersResult.signedHeaders ~ ", Signature=" ~ signatureHex;

    return SignedRequest(canonicalRequest, stringToSign, credentialScope, signatureHex, authorizationHeader);
}
