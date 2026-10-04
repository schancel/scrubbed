/// Fixed-capacity text helpers for the collector-free core: a bounded writer
/// over caller memory, an inline (in-struct) string, and the few ASCII
/// primitives the core needs. Nothing here allocates or throws; running out
/// of room is a flag the caller checks, never a truncated result used as if
/// it were whole.
module s3lite.fixed;

@nogc nothrow pure:

/// Appends text into a caller-supplied buffer. Once a write does not fit,
/// `overflow` is set and stays set; every later write is ignored, so one
/// check at the end of a sequence is enough.
struct Writer {
    char[] buf;
    size_t len;
    bool overflow;

@nogc nothrow pure:

    this(char[] buffer) { buf = buffer; }

    void put(scope const(char)[] text) {
        if (overflow) return;
        if (text.length > buf.length - len) { overflow = true; return; }
        buf[len .. len + text.length] = text[];
        len += text.length;
    }

    void put(char c) {
        if (overflow) return;
        if (len == buf.length) { overflow = true; return; }
        buf[len++] = c;
    }

    /// Decimal rendering of `value`.
    void putUnsigned(ulong value) {
        char[20] digits = void;
        size_t i = digits.length;
        do {
            digits[--i] = cast(char)('0' + value % 10);
            value /= 10;
        } while (value != 0);
        put(digits[i .. $]);
    }

    size_t mark() const { return len; }

    /// Everything written since `from` (a value `mark` returned).
    inout(char)[] since(size_t from) inout { return buf[from .. len]; }

    /// The unwritten remainder of the buffer.
    char[] spare() { return buf[len .. $]; }

    /// Discards everything written after `to`, zeroing it first when
    /// `wipe` is set (used for key material).
    void rewind(size_t to, bool wipe = false) {
        if (to > len) return;
        if (wipe) buf[to .. len] = '\0';
        len = to;
    }
}

/// A string stored inside the value that carries it, so a result can be
/// returned and copied across threads without owning or borrowing memory.
/// Text longer than `N` is cut and `truncated` is set.
struct InlineText(size_t N) {
    private char[N] data_ = '\0';
    private ushort length_;
    bool truncated;

@nogc nothrow pure:

    /// View of the stored text; valid as long as this value is.
    const(char)[] text() const return { return data_[0 .. length_]; }
    alias opSlice = text;

    size_t length() const { return length_; }

    void clear() { length_ = 0; truncated = false; }

    void set(scope const(char)[] value) {
        clear();
        append(value);
    }

    void append(scope const(char)[] value) {
        auto room = N - length_;
        auto n = value.length;
        if (n > room) { n = room; truncated = true; }
        data_[length_ .. length_ + n] = value[0 .. n];
        length_ += cast(ushort) n;
    }

    void append(char c) {
        if (length_ == N) { truncated = true; return; }
        data_[length_++] = c;
    }
}

char toLowerAscii(char c) {
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

/// ASCII case-insensitive equality.
bool equalIgnoreCase(scope const(char)[] a, scope const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (toLowerAscii(a[i]) != toLowerAscii(b[i])) return false;
    return true;
}

bool startsWith(scope const(char)[] text, scope const(char)[] prefix) {
    return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
}

/// Index of the first `needle` at or after `from`, or -1.
ptrdiff_t indexOf(scope const(char)[] haystack, scope const(char)[] needle, size_t from = 0) {
    if (needle.length == 0) return from <= haystack.length ? from : -1;
    if (haystack.length < needle.length) return -1;
    foreach (i; from .. haystack.length - needle.length + 1)
        if (haystack[i] == needle[0] && haystack[i .. i + needle.length] == needle) return i;
    return -1;
}

/// ditto
ptrdiff_t indexOf(scope const(char)[] haystack, char needle, size_t from = 0) {
    foreach (i; from .. haystack.length)
        if (haystack[i] == needle) return i;
    return -1;
}

/// Strips spaces and tabs (and CR/LF) from both ends.
inout(char)[] trim(return scope inout(char)[] text) {
    static bool blank(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
    while (text.length && blank(text[0])) text = text[1 .. $];
    while (text.length && blank(text[$ - 1])) text = text[0 .. $ - 1];
    return text;
}

/// Parses an unsigned decimal number occupying all of `text`. Returns false
/// on an empty string, a non-digit, or overflow.
bool parseUnsigned(scope const(char)[] text, out ulong value) {
    if (text.length == 0) return false;
    ulong v = 0;
    foreach (c; text) {
        if (c < '0' || c > '9') return false;
        immutable digit = cast(ulong)(c - '0');
        if (v > (ulong.max - digit) / 10) return false;
        v = v * 10 + digit;
    }
    value = v;
    return true;
}

unittest {
    char[8] storage;
    auto w = Writer(storage[]);
    w.put("abc");
    w.putUnsigned(1200);
    assert(w.since(0) == "abc1200" && !w.overflow);
    w.put("xy");
    assert(w.overflow && w.since(0) == "abc1200");
}

unittest {
    InlineText!4 t;
    t.set("ab");
    assert(t[] == "ab" && !t.truncated);
    t.append("cdef");
    assert(t[] == "abcd" && t.truncated);
}

unittest {
    ulong v;
    assert(parseUnsigned("18446744073709551615", v) && v == ulong.max);
    assert(!parseUnsigned("18446744073709551616", v));
    assert(!parseUnsigned("", v) && !parseUnsigned("12a", v));
    assert(equalIgnoreCase("ETag", "etag") && !equalIgnoreCase("ETag", "etags"));
    assert(indexOf("abcabc", "ca") == 2 && indexOf("abc", 'c', 3) == -1);
    assert(trim("  a b\r\n") == "a b");
}
