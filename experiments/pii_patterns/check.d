module pii_patterns.check;

import domain.pii_patterns;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.stdio : writeln;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private PiiFinding[] scan(string value, string locale = "US") {
    return scanPii(cast(const(ubyte)[]) value, locale);
}

private void rejects(string message, scope void delegate() action) {
    try action();
    catch (PiiScanException e) {
        check(e.msg == "pii scan: " ~ message, "wrong safe diagnostic");
        return;
    }
    throw new Exception("expected rejection");
}

private void golden() {
    auto us = scan("é a.b+tag@example.co +1-202-555-0142 4111 1111 1111 1111 192.0.2.1");
    check(us.length == 4, "US finding count");
    check(us[0] == PiiFinding(3, 21, PiiCategory.email, "email.ascii-domain.v1", "US", PiiConfidence.high), "email byte span");
    check(us[1] == PiiFinding(22, 37, PiiCategory.phone, "phone.international.v1", "US", PiiConfidence.high), "US phone span");
    check(us[2] == PiiFinding(38, 57, PiiCategory.card, "card.luhn.ambiguous.v1", "US", PiiConfidence.ambiguous), "card span");
    check(us[3] == PiiFinding(58, 67, PiiCategory.ip, "ip.v4.v1", "US", PiiConfidence.high), "IP span");
    auto gb = scan("+44 20 7946 0958 | 020 7946 0958", "GB");
    check(gb.length == 2 && gb[0].start == 0 && gb[0].end == 16 &&
        gb[0].confidence == PiiConfidence.high && gb[1].start == 19 && gb[1].end == 32 &&
        gb[1].confidence == PiiConfidence.ambiguous, "GB locale golden");
    check(scan("202-555-0142")[0].confidence == PiiConfidence.ambiguous, "US national ambiguity");
    check(scan("+1-202-555-0142", "GB").length == 0 &&
        scan("+44 20 7946 0958", "US").length == 0, "locale separation");
    auto overlap = scan("202-555-0142@example.com");
    check(overlap.length == 2 && overlap[0].start == 0 && overlap[1].start == 0 &&
        overlap[0].category == PiiCategory.phone && overlap[1].category == PiiCategory.email,
        "overlaps retained");
}

private void negatives() {
    void countFalsePositives(string label, string[] samples, string locale = "US") {
        size_t count;
        foreach (sample; samples) count += scan(sample, locale).length;
        check(count == 0, label ~ " synthetic false-positive count");
    }
    countFalsePositives("email", ["a..b@example.com", ".a@example.com", "a@-example.com",
        "a@example.c", "a@example.123", "a@example..com", "x_a@example.com_"]);
    countFalsePositives("IPv4", ["256.1.1.1", "01.2.3.4", "1.2.3.999", "1.2.3.4.5"]);
    countFalsePositives("card", ["1111 1111 1111 1111", "0000 0000 0000 0000",
        "4111 1111 1111 1112"]);
    countFalsePositives("US phone", ["123-555-0142", "202-055-0142",
        "202-555-01420", "020 7946 0958"]);
    countFalsePositives("GB phone", ["+44 20 7946 095", "020 7946 095",
        "+1-202-555-0142"], "GB");
    check(scan("éhello@example.com").length == 1, "Unicode byte boundary");
}

private void punctuationBoundaries() {
    void terminal(string prefix, string token, PiiCategory category) {
        auto result = scan(prefix ~ token ~ ".");
        check(result.length == 1 && result[0].start == prefix.length &&
            result[0].end == prefix.length + token.length &&
            result[0].category == category, "terminal punctuation byte span");
    }
    terminal("Sentence: ", "a@example.com", PiiCategory.email);
    terminal("Sentence: ", "192.0.2.1", PiiCategory.ip);
    terminal("Sentence: ", "202-555-0142", PiiCategory.phone);
    terminal("Sentence: ", "4111 1111 1111 1111", PiiCategory.card);
    check(scan("a@example.com@evil.com").length == 0, "chained at-sign is not two emails");
    check(scan("a@example.com.more").length == 1 &&
        scan("a@example.com.more")[0].end == "a@example.com.more".length,
        "legitimate domain extension retained");
    check(scan("a@example.com..more").length == 0, "double-dot extension rejected");
    check(scan("192.0.2.1.5").length == 0 &&
        scan("202-555-0142.9").length == 0 &&
        scan("4111 1111 1111 1111.9").length == 0,
        "malformed numeric extensions rejected");
    check(scan("4111 1111 1111 1111 1234").length == 0,
        "fifth same-separated card group rejected");
    check(scan("4111 1111 1111 1111 is a fixture").length == 1,
        "card followed by prose retained");
}

private void boundsAndSafety() {
    rejects("unsupported locale", { scan("canary@example.com", "XX"); });
    rejects("invalid UTF-8", { scanPii([cast(ubyte)0xff], "US"); });
    rejects("input exceeds cap", {
        auto huge = new ubyte[maxPiiInputBytes + 1];
        scanPii(huge, "US");
    });
    rejects("findings exceed cap", {
        string many;
        foreach (_; 0 .. maxPiiFindings + 1) many ~= "a@b.co ";
        scan(many);
    });
    auto value = "canary.secret@example.com";
    auto result = scan(value);
    check(result.length == 1, "canary missing");
    check(!result.to!string.canFind("canary") &&
        !result.to!string.canFind("secret"), "finding diagnostic leaked matched text");
    check(scan("4111 1111 1111 1111").length == 1, "valid checksum");
    check(scan("a@b.co 192.0.2.1") == scan("a@b.co 192.0.2.1"), "determinism");
}

void main() {
    golden();
    negatives();
    punctuationBoundaries();
    boundsAndSafety();
    writeln("pii patterns: release-active goldens passed");
}
