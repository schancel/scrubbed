module pii_policy.check;

import domain.pii_patterns;
import domain.pii_policy;
import core.sys.posix.fcntl : fcntl, F_GETFD;
import core.sys.posix.stdlib : mkstemp;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.sys.stat : fstat, stat_t;
import core.sys.posix.unistd : close, write;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : read;
import std.stdio : writeln;
import std.string : fromStringz;

private void check(bool yes, string reason) {
    if (!yes) throw new Exception(reason);
}

private ubyte[] bytes(string value) { return cast(ubyte[]) value.dup; }
private string asText(const(ubyte)[] value) { return cast(string) value; }

private PiiPolicyResult apply(string text, PiiPolicy policy,
        bool allowRedact = false, string locale = "US") {
    auto source = bytes(text);
    auto before = source.dup;
    auto findings = scanPii(source, locale);
    auto result = applyPiiPolicy(source, findings, policy, allowRedact);
    check(source == before, "source bytes changed");
    return result;
}

private void rejects(string diagnostic, scope void delegate() action) {
    try action();
    catch (PiiPolicyException e) {
        check(e.msg == "pii policy: " ~ diagnostic, "wrong safe diagnostic");
        return;
    }
    throw new Exception("expected policy rejection");
}

private void goldens() {
    enum text = "é a.b+tag@example.co +1-202-555-0142 4111 1111 1111 1111; 192.0.2.1";
    auto report = apply(text, PiiPolicy.report);
    check(asText(report.output) == text && report.policy == PiiPolicy.report &&
        report.audit.length == 4, "report golden");
    check(report.audit[0].start == 3 && report.audit[0].end == 21 &&
        report.audit[0].contributors[0].rule == PiiRule.emailAsciiDomain &&
        report.audit[0].contributors[0].locale == PiiLocale.us &&
        report.audit[0].outcome == PiiOutcome.reported, "email audit golden");
    check(report.audit[1].contributors[0].rule == PiiRule.phoneInternational &&
        report.audit[2].contributors[0].rule == PiiRule.cardLuhn &&
        report.audit[2].contributors[0].confidence == PiiConfidence.ambiguous &&
        report.audit[3].contributors[0].rule == PiiRule.ipv4,
        "typed four-class audit");
    auto masked = apply(text, PiiPolicy.mask);
    check(asText(masked.output) == "é ****************** *************** *******************; *********" &&
        masked.output.length == text.length && masked.audit[0].outcome == PiiOutcome.masked,
        "mask golden preserves byte offsets");
    auto redacted = apply(text, PiiPolicy.redact, true);
    check(asText(redacted.output) ==
        "é [REDACTED] [REDACTED] [REDACTED]; [REDACTED]" &&
        redacted.audit[0].outcome == PiiOutcome.redacted, "redact golden");
    auto gb = apply("020 7946 0958", PiiPolicy.report, false, "GB");
    check(gb.audit.length == 1 && gb.audit[0].contributors[0].locale == PiiLocale.gb &&
        gb.audit[0].contributors[0].rule == PiiRule.phoneNational &&
        gb.audit[0].contributors[0].confidence == PiiConfidence.ambiguous,
        "GB ambiguous golden");
}

private void overlapAndAdjacency() {
    enum text = "abcdefghij";
    auto source = bytes(text);
    PiiFinding[] findings = [
        PiiFinding(0, 4, PiiCategory.email, "email.ascii-domain.v1", "US", PiiConfidence.high),
        PiiFinding(1, 3, PiiCategory.card, "card.luhn.ambiguous.v1", "US", PiiConfidence.ambiguous),
        PiiFinding(3, 7, PiiCategory.ip, "ip.v4.v1", "US", PiiConfidence.high),
        PiiFinding(7, 9, PiiCategory.phone, "phone.national.ambiguous.v1", "US", PiiConfidence.ambiguous),
    ];
    auto masked = applyPiiPolicy(source, findings, PiiPolicy.mask);
    check(asText(masked.output) == "*********j" && masked.audit.length == 2 &&
        masked.audit[0].start == 0 && masked.audit[0].end == 7 &&
        masked.audit[0].contributors.length == 3 &&
        masked.audit[1].start == 7 && masked.audit[1].contributors.length == 1,
        "overlap union and adjacent separation");
    auto redacted = applyPiiPolicy(source, findings, PiiPolicy.redact, true);
    check(asText(redacted.output) == "[REDACTED][REDACTED]j" &&
        redacted.audit[0].contributors[1].confidence == PiiConfidence.ambiguous,
        "contributors retained under redact");
    check(applyPiiPolicy(source, findings, PiiPolicy.redact, true) == redacted,
        "deterministic decision");
    auto scannerOverlap = apply("202-555-0142@example.com", PiiPolicy.redact, true);
    check(scannerOverlap.audit.length == 1 &&
        scannerOverlap.audit[0].contributors.length == 2 &&
        asText(scannerOverlap.output) == "[REDACTED]", "real scanner overlap");
}

private void boundariesAndSafety() {
    auto source = bytes("éx");
    auto before = source.dup;
    PiiFinding valid = PiiFinding(2, 3, PiiCategory.email,
        "email.ascii-domain.v1", "US", PiiConfidence.high);
    check(asText(applyPiiPolicy(source, [valid], PiiPolicy.mask).output) == "é*",
        "Unicode-adjacent ASCII mask");
    rejects("invalid finding span", {
        auto bad = valid; bad.start = 1;
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("invalid finding span", {
        auto bad = valid; bad.end = 4;
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("invalid finding span", {
        auto bad = valid; bad.end = bad.start;
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("findings not strictly ordered", {
        applyPiiPolicy(source, [valid, valid], PiiPolicy.mask);
    });
    rejects("findings not strictly ordered", {
        auto first = valid; first.start = 0; first.end = 2;
        applyPiiPolicy(source, [valid, first], PiiPolicy.mask);
    });
    rejects("unsupported locale", {
        auto bad = valid; bad.locale = "XX";
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("unsupported rule or confidence", {
        auto bad = valid; bad.rule = "private-canary@example.com";
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("unsupported rule or confidence", {
        auto bad = valid; bad.confidence = PiiConfidence.ambiguous;
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("unsupported rule or confidence", {
        auto bad = valid; bad.category = cast(PiiCategory) 99;
        applyPiiPolicy(source, [bad], PiiPolicy.mask);
    });
    rejects("invalid UTF-8", {
        applyPiiPolicy([cast(ubyte) 0xff], [], PiiPolicy.report);
    });
    rejects("input exceeds cap", {
        applyPiiPolicy(new ubyte[maxPiiInputBytes + 1], [], PiiPolicy.report);
    });
    rejects("findings exceed cap", {
        applyPiiPolicy(source, new PiiFinding[maxPiiFindings + 1], PiiPolicy.report);
    });
    rejects("unsupported policy", {
        applyPiiPolicy(source, [], cast(PiiPolicy) 99);
    });
    rejects("redact requires opt-in", {
        applyPiiPolicy(source, [valid], PiiPolicy.redact);
    });
    check(source == before, "rejection changed source");
    check(asText(applyPiiPolicy(source, [], PiiPolicy.redact, true).output) == "éx",
        "empty findings preserve content");
    auto canary = apply("private-canary@example.com", PiiPolicy.report);
    check(!canary.audit.to!string.canFind("private-canary") &&
        !canary.audit.to!string.canFind("@example") &&
        !canary.audit.to!string.canFind("private"), "audit leaked matched content");
}

private size_t openFds() {
    size_t count;
    foreach (fd; 0 .. 1024) if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

private ulong rssBytes() {
    rusage usage;
    check(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation");
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "RSS observation requires platform support");
}

private void fileAndResourceBoundary() {
    char[] templateName = "/tmp/scrubd-pii-policy-XXXXXX\0".dup;
    auto fd = mkstemp(templateName.ptr);
    check(fd >= 0, "fixture creation");
    auto path = fromStringz(templateName.ptr).idup;
    scope (exit) {
        close(fd);
        import std.file : remove;
        remove(path);
    }
    enum content = "private-canary@example.com";
    check(write(fd, content.ptr, content.length) == content.length, "fixture write");
    stat_t before, after;
    check(fstat(fd, &before) == 0, "fixture stat before");
    auto source = cast(ubyte[]) read(path);
    auto finding = scanPii(source, "US");
    auto sourceCopy = source.dup;
    rejects("redact requires opt-in", {
        applyPiiPolicy(source, finding, PiiPolicy.redact);
    });
    auto decision = applyPiiPolicy(source, finding, PiiPolicy.redact, true);
    check(asText(decision.output) == "[REDACTED]" && source == sourceCopy &&
        cast(ubyte[]) read(path) == sourceCopy, "fixture bytes preserved");
    check(fstat(fd, &after) == 0 && before.st_ino == after.st_ino &&
        before.st_size == after.st_size, "fixture inode preserved");

    auto rssBefore = rssBytes();
    auto fdsBefore = openFds();
    auto bounded = new ubyte[maxPiiInputBytes];
    PiiFinding[] many;
    foreach (i; 0 .. maxPiiFindings)
        many ~= PiiFinding(i * 2, i * 2 + 1, PiiCategory.ip,
            "ip.v4.v1", "US", PiiConfidence.high);
    foreach (_; 0 .. 16) {
        auto output = applyPiiPolicy(bounded, many, PiiPolicy.redact, true);
        check(output.audit.length == maxPiiFindings && output.output.length <=
            maxPiiInputBytes + maxPiiFindings * 10, "bounded output");
    }
    check(openFds() == fdsBefore, "FD growth");
    check(rssBytes() <= rssBefore + 128 * 1024 * 1024,
        "RSS growth");
}

void main() {
    goldens();
    overlapAndAdjacency();
    boundariesAndSafety();
    fileAndResourceBoundary();
    writeln("pii policy: release-active goldens passed");
}
