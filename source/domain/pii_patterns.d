/// Bounded, deterministic recognizers for four high-confidence ASCII PII forms.
/// Offsets always refer to the original UTF-8 byte stream.
module domain.pii_patterns;

import std.algorithm.sorting : sort;
import std.utf : validate;

enum size_t maxPiiInputBytes = 1024 * 1024;
enum size_t maxPiiFindings = 4096;

enum PiiCategory { email, phone, card, ip }
enum PiiConfidence { high, ambiguous }

struct PiiFinding {
    size_t start;
    size_t end; // exclusive
    PiiCategory category;
    string rule;
    string locale;
    PiiConfidence confidence;
}

class PiiScanException : Exception {
    this(string message) { super("pii scan: " ~ message); }
}

private bool digit(ubyte c) { return c >= '0' && c <= '9'; }
private bool alpha(ubyte c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
private bool alnum(ubyte c) { return alpha(c) || digit(c); }
private bool localChar(ubyte c) {
    return alnum(c) || c == '.' || c == '_' || c == '%' || c == '+' || c == '-';
}
private bool word(ubyte c) { return alnum(c) || c == '_'; }
private bool leftClear(const(ubyte)[] b, size_t i) { return i == 0 || !word(b[i - 1]); }
private bool rightClear(const(ubyte)[] b, size_t i) { return i == b.length || !word(b[i]); }
private bool terminalDot(const(ubyte)[] b, size_t i) {
    if (i == b.length || b[i] != '.') return false;
    if (i + 1 == b.length) return true;
    auto next = b[i + 1];
    return next == ' ' || next == '\n' || next == '\r' || next == '\t' ||
        next == ')' || next == ']' || next == '}' || next == '"' || next == '\'';
}

private size_t emailEnd(const(ubyte)[] b, size_t i) {
    if ((i > 0 && (localChar(b[i - 1]) || b[i - 1] == '@')) || !alnum(b[i])) return i;
    size_t p = i;
    while (p < b.length && localChar(b[p])) {
        if (b[p] == '.' && (p == i || p + 1 == b.length || b[p + 1] == '.')) return i;
        ++p;
    }
    if (p == i || b[p - 1] == '.' || p >= b.length || b[p] != '@' || p - i > 64) return i;
    ++p;
    size_t domainStart = p;
    size_t dots;
    size_t lastLabel = p;
    while (p < b.length && (alnum(b[p]) || b[p] == '-' || b[p] == '.')) {
        if (terminalDot(b, p)) break;
        if (b[p] == '.') {
            if (p == lastLabel || b[p - 1] == '-' || p - lastLabel > 63) return i;
            ++dots;
            lastLabel = p + 1;
        } else if (b[p] == '-' && p == lastLabel) return i;
        ++p;
    }
    if (dots == 0 || p == lastLabel || p - lastLabel < 2 || p - lastLabel > 63 ||
        p - domainStart > 253 || b[p - 1] == '-' || !rightClear(b, p) ||
        (p < b.length && b[p] == '@')) return i;
    foreach (c; b[lastLabel .. p]) if (!alpha(c)) return i;
    return p;
}

private size_t ipEnd(const(ubyte)[] b, size_t i) {
    if (!leftClear(b, i) || (i > 0 && b[i - 1] == '.') || !digit(b[i])) return i;
    size_t p = i;
    foreach (part; 0 .. 4) {
        size_t begin = p;
        uint value;
        while (p < b.length && digit(b[p]) && p - begin < 3) value = value * 10 + b[p++] - '0';
        if (p == begin || (p - begin > 1 && b[begin] == '0') || value > 255 ||
            (p < b.length && digit(b[p]))) return i;
        if (part < 3) {
            if (p == b.length || b[p++] != '.') return i;
        }
    }
    return rightClear(b, p) && (p == b.length || b[p] != '.' || terminalDot(b, p)) ? p : i;
}

private bool luhn(const(ubyte)[] b, size_t i, size_t end) {
    uint sum;
    bool doubled;
    for (size_t p = end; p > i;) {
        auto c = b[--p];
        if (!digit(c)) continue;
        uint n = c - '0';
        if (doubled) { n *= 2; if (n > 9) n -= 9; }
        sum += n;
        doubled = !doubled;
    }
    return sum % 10 == 0;
}

private bool plausibleCardPrefix(const(ubyte)[] b, size_t i, size_t count) {
    ubyte[4] first;
    size_t n;
    for (size_t p = i; p < b.length && n < 4; ++p)
        if (digit(b[p])) first[n++] = b[p];
    auto two = (first[0] - '0') * 10 + first[1] - '0';
    auto four = two * 100 + (first[2] - '0') * 10 + first[3] - '0';
    if (first[0] == '4') return count == 13 || count == 16 || count == 19;
    if (count == 15 && (two == 34 || two == 37)) return true;
    if (count == 16 && ((two >= 51 && two <= 55) || (four >= 2221 && four <= 2720))) return true;
    return (count == 16 || count == 19) && (four == 6011 || two == 65);
}

private size_t cardEnd(const(ubyte)[] b, size_t i) {
    if (!leftClear(b, i) || !digit(b[i])) return i;
    size_t p = i, count, group;
    ubyte separator;
    while (p < b.length && count <= 19) {
        if (digit(b[p])) { ++p; ++count; ++group; continue; }
        if ((b[p] == ' ' || b[p] == '-') && p + 1 < b.length && digit(b[p + 1]) &&
            (separator == 0 || separator == b[p]) && group == 4 && count < 16) {
            separator = b[p++]; group = 0; continue;
        }
        break;
    }
    if (count < 13 || count > 19 || (separator != 0 && (count != 16 || group != 4)) ||
        !rightClear(b, p) ||
        (p < b.length && (digit(b[p]) || (b[p] == '.' && !terminalDot(b, p)) || b[p] == '-')) ||
        !plausibleCardPrefix(b, i, count) || !luhn(b, i, p)) return i;
    // A fifth same-separated four-digit group is a malformed extension,
    // whereas a following prose word is a legitimate delimiter.
    if (separator != 0 && p + 5 <= b.length && b[p] == separator &&
        digit(b[p + 1]) && digit(b[p + 2]) && digit(b[p + 3]) && digit(b[p + 4])) return i;
    return p;
}

private size_t phoneEnd(const(ubyte)[] b, size_t i, string locale, out bool ambiguous) {
    ambiguous = false;
    if (!leftClear(b, i) || (i > 0 && (b[i - 1] == '-' || b[i - 1] == '+'))) return i;
    size_t p = i;
    bool international;
    if (locale == "US") {
        if (p + 3 <= b.length && b[p .. p + 3] == cast(const(ubyte)[]) "+1-") {
            p += 3; international = true;
        }
        if (p + 12 > b.length || b[p] < '2' || b[p] > '9' || !digit(b[p + 1]) ||
            !digit(b[p + 2]) || b[p + 3] != '-' || b[p + 4] < '2' || b[p + 4] > '9' ||
            !digit(b[p + 5]) || !digit(b[p + 6]) || b[p + 7] != '-') return i;
        foreach (c; b[p + 8 .. p + 12]) if (!digit(c)) return i;
        p += 12;
    } else {
        if (p + 4 <= b.length && b[p .. p + 4] == cast(const(ubyte)[]) "+44 ") {
            p += 4; international = true;
            if (p + 12 > b.length || b[p .. p + 3] != cast(const(ubyte)[]) "20 ") return i;
            p += 3;
        } else {
            if (p + 13 > b.length || b[p .. p + 4] != cast(const(ubyte)[]) "020 ") return i;
            p += 4;
        }
        foreach (c; b[p .. p + 4]) if (!digit(c)) return i;
        p += 4;
        if (p >= b.length || b[p++] != ' ') return i;
        foreach (c; b[p .. p + 4]) if (!digit(c)) return i;
        p += 4;
    }
    if (!rightClear(b, p) || (p < b.length &&
        (b[p] == '-' || (b[p] == '.' && !terminalDot(b, p))))) return i;
    ambiguous = !international;
    return p;
}

/// Scan C01 content bytes. Throws only fixed, non-content-bearing diagnostic messages.
PiiFinding[] scanPii(const(ubyte)[] bytes, string locale) {
    if (locale != "US" && locale != "GB") throw new PiiScanException("unsupported locale");
    if (bytes.length > maxPiiInputBytes) throw new PiiScanException("input exceeds cap");
    try validate(cast(string) bytes);
    catch (Exception) throw new PiiScanException("invalid UTF-8");
    PiiFinding[] findings;
    void add(size_t start, size_t end, PiiCategory category, string rule,
             PiiConfidence confidence = PiiConfidence.high) {
        if (end == start) return;
        if (findings.length >= maxPiiFindings) throw new PiiScanException("findings exceed cap");
        findings ~= PiiFinding(start, end, category, rule, locale, confidence);
    }
    foreach (i; 0 .. bytes.length) {
        auto e = emailEnd(bytes, i);
        add(i, e, PiiCategory.email, "email.ascii-domain.v1");
        e = ipEnd(bytes, i);
        add(i, e, PiiCategory.ip, "ip.v4.v1");
        e = cardEnd(bytes, i);
        add(i, e, PiiCategory.card, "card.luhn.ambiguous.v1", PiiConfidence.ambiguous);
        bool ambiguous;
        e = phoneEnd(bytes, i, locale, ambiguous);
        add(i, e, PiiCategory.phone, ambiguous ? "phone.national.ambiguous.v1" :
            "phone.international.v1", ambiguous ? PiiConfidence.ambiguous : PiiConfidence.high);
    }
    sort!((a, b) => a.start < b.start || (a.start == b.start &&
        (a.end < b.end || (a.end == b.end && a.category < b.category))))(findings);
    return findings;
}
