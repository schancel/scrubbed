/// Release-active goldens for the bounded web URL and discovery seam.
module experiments.url_discovery.check;

import effects.web_url;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.string : indexOf;
import std.stdio : writeln;
import std.conv : to;

private size_t checks;

private void need(bool condition, string label) {
    ++checks;
    if (!condition) throw new Exception("url-discovery check failed: " ~ label);
}

private const(WebUrl) resolved(string response, string reference,
        string base = null) {
    auto outcome = resolveWebUrl(response, reference, base);
    need(outcome.isResolved, "expected resolution");
    return outcome.value;
}

private void golden(string response, string reference, string expected,
        string base = null) {
    auto value = resolved(response, reference, base);
    need(value.policy == webUrlPolicy, "policy version");
    need(value.canonical == expected, "canonical golden");
}

private void rejects(string response, string reference, WebUrlInput input,
        WebUrlFailureReason reason, string base = null) {
    auto outcome = resolveWebUrl(response, reference, base);
    need(!outcome.isResolved, "expected rejection");
    need(outcome.failure == WebUrlFailure(input, reason),
        "typed rejection " ~ input.to!string ~ "/" ~ reason.to!string ~
        " got " ~ outcome.failure.input.to!string ~ "/" ~
        outcome.failure.reason.to!string);
}

private string repeated(char value, size_t length) {
    auto result = new char[length];
    result[] = value;
    return cast(string) result;
}

private string repeatedText(string value, size_t count) {
    string result;
    result.reserve(value.length * count);
    foreach (_; 0 .. count) result ~= value;
    return result;
}

void main() {
    golden("https://example.test/a/b/index.html", "../asset",
        "https://example.test/a/asset");
    golden("https://example.test/root/page", "asset",
        "https://cdn.example.test/static/asset",
        "https://cdn.example.test/static/");
    golden("HTTP://EXAMPLE.TEST:80/a/./b/../c", "",
        "http://example.test/a/c");
    golden("https://example.test/", "/p#section",
        "https://example.test/p");
    auto fragment = resolved("https://example.test/", "/p#section");
    need(fragment.hasFragment && fragment.fragment == "section",
        "fragment evidence");
    auto emptyFragment = resolved("https://example.test/", "/p#");
    need(emptyFragment.hasFragment && emptyFragment.fragment.length == 0,
        "empty fragment evidence");
    golden("https://example.test/", "/?b=2&a=1&a=3",
        "https://example.test/?b=2&a=1&a=3");
    golden("https://example.test/", "/a%2Fb?q=x%20y",
        "https://example.test/a%2Fb?q=x%20y");
    golden("https://example.test/", "https://bücher.example/straße",
        "https://xn--bcher-kva.example/stra%C3%9Fe");
    golden("https://example.test/", "http://127.0.0.1:80/a",
        "http://127.0.0.1/a");
    golden("https://example.test/", "http://[2001:0db8::1]:80/a",
        "http://[2001:db8::1]/a");

    rejects("https://example.test/", "https://user@example.test/",
        WebUrlInput.reference, WebUrlFailureReason.credentials);
    rejects("https://example.test/", "mailto:user@example.test",
        WebUrlInput.reference, WebUrlFailureReason.unsupportedScheme);
    rejects("https://example.test/", "http://[::1",
        WebUrlInput.reference, WebUrlFailureReason.malformed);
    rejects("https://example.test/", "https://example.test/a b",
        WebUrlInput.reference, WebUrlFailureReason.malformed);
    rejects("https://user@example.test/", "/safe",
        WebUrlInput.response, WebUrlFailureReason.credentials);
    rejects("https://example.test/", "/safe",
        WebUrlInput.documentBase, WebUrlFailureReason.unsupportedScheme,
        "file:///tmp/");
    rejects("https://example.test/", repeated('x', maxWebUrlBytes + 1),
        WebUrlInput.reference, WebUrlFailureReason.oversized);
    rejects(repeated('x', maxWebUrlBytes + 1), "/safe",
        WebUrlInput.response, WebUrlFailureReason.oversized);
    auto expanded = "/" ~ repeatedText("é", 700);
    rejects("https://example.test/", expanded, WebUrlInput.reference,
        WebUrlFailureReason.outputLimit);
    auto invalidUtf8 = cast(string) [cast(char) 0xff];
    rejects("https://example.test/", invalidUtf8, WebUrlInput.reference,
        WebUrlFailureReason.invalidUtf8);

    auto first = resolved("https://example.test/a/", "b?x=1&x=1#f");
    auto second = resolved("https://example.test/a/", "b?x=1&x=1#f");
    need(first == second, "deterministic value bytes");
    need(first.canonical == "https://example.test/a/b?x=1&x=1",
        "duplicates retained");

    auto same = resolved("https://EXAMPLE.test:443/a", "/b");
    auto port = resolved("https://example.test/", "https://example.test:444/b");
    auto scheme = resolved("https://example.test/", "http://example.test/b");
    auto host = resolved("https://example.test/", "https://other.test/b");
    need(first.sameOrigin(same), "canonical same origin");
    need(!first.sameOrigin(port), "different port");
    need(!first.sameOrigin(scheme), "different scheme");
    need(!first.sameOrigin(host), "different host");

    string raw = "/private?token=secret#account";
    auto discovered = discoverWebUrl("https://example.test/ref#old", raw,
        RelationKind.hyperlink, 17, AttributeKind.href, 3);
    need(discovered.isDiscovered, "candidate discovered");
    need(discovered.value.evidence.referrer.canonical ==
        "https://example.test/ref", "canonical referrer");
    need(discovered.value.evidence.relation == RelationKind.hyperlink &&
        discovered.value.evidence.nodeOrdinal == 17 &&
        discovered.value.evidence.attribute == AttributeKind.href &&
        discovered.value.evidence.depth == 3, "typed evidence");
    need(discovered.value.evidence.rawValueDigest ==
        toHexString!(LetterCase.lower)(sha256Of(raw)).idup,
        "raw value digest");
    need(discovered.value.evidence.rawValueDigest.indexOf("secret") < 0,
        "secret-free evidence");

    auto bad = discoverWebUrl("https://example.test/", "https://u:p@host/secret",
        RelationKind.embeddedResource, 9, AttributeKind.src, 2);
    need(!bad.isDiscovered && bad.failure.reason ==
        WebUrlFailureReason.credentials, "secret-free failure");

    char[] responseStorage = "https://example.test/base/page".dup;
    char[] referenceStorage = "../owned#fragment".dup;
    auto owned = resolveWebUrl(cast(string) responseStorage,
        cast(string) referenceStorage);
    need(owned.isResolved, "lifetime setup");
    responseStorage[] = 'x';
    referenceStorage[] = 'y';
    need(owned.value.canonical == "https://example.test/owned" &&
        owned.value.fragment == "fragment" &&
        owned.value.origin == "https://example.test",
        "native and input lifetime ownership");

    writeln("url-discovery release checks passed: ", checks);
}
