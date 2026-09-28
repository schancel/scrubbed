/// Minimal parser for S3's real REST error response shape:
///
///   <?xml version="1.0" encoding="UTF-8"?>
///   <Error><Code>NoSuchKey</Code><Message>...</Message>...</Error>
///
/// Deliberately not a general-purpose XML parser (and not a dependency on
/// one, keeping this package at zero dependencies) -- S3's own error body is
/// a small, flat, well-known tag set, so a targeted tag extractor is enough
/// to distinguish real error codes and is easy to verify against real S3
/// responses (see tests/live_public_object.d).
module s3lite.xml_error;

struct ParsedS3Error {
    bool valid;   // true if this looked like a well-formed <Error>...</Error> body
    string code;    // e.g. "NoSuchKey", "AccessDenied", "NoSuchBucket"
    string message;
}

private string decodeEntities(string s) pure {
    import std.array : appender;
    auto result = appender!string;
    size_t i = 0;
    while (i < s.length) {
        if (s[i] == '&') {
            if (i + 4 <= s.length && s[i .. i + 4] == "&lt;") { result ~= '<'; i += 4; continue; }
            if (i + 4 <= s.length && s[i .. i + 4] == "&gt;") { result ~= '>'; i += 4; continue; }
            if (i + 5 <= s.length && s[i .. i + 5] == "&amp;") { result ~= '&'; i += 5; continue; }
            if (i + 6 <= s.length && s[i .. i + 6] == "&quot;") { result ~= '"'; i += 6; continue; }
            if (i + 6 <= s.length && s[i .. i + 6] == "&apos;") { result ~= '\''; i += 6; continue; }
        }
        result ~= s[i];
        i++;
    }
    return result.data;
}

private string extractTag(string xml, string tag) pure {
    import std.string : indexOf;
    auto open = "<" ~ tag ~ ">";
    auto close = "</" ~ tag ~ ">";
    auto start = xml.indexOf(open);
    if (start < 0) return null;
    start += open.length;
    auto end = xml.indexOf(close, start);
    if (end < 0) return null;
    return decodeEntities(xml[start .. end]);
}

/// Parses an S3 error-response body. Returns `valid == false` (not an
/// exception) if the body doesn't contain a recognizable `<Error>` element
/// with both `<Code>` and `<Message>` -- callers treat that as
/// `malformedResponse`, not a crash.
ParsedS3Error parseS3Error(scope const(ubyte)[] body_) pure {
    auto text = cast(string) body_.idup;
    import std.string : indexOf;
    if (text.indexOf("<Error>") < 0 && text.indexOf("<Error ") < 0)
        return ParsedS3Error(false, null, null);
    auto code = extractTag(text, "Code");
    auto message = extractTag(text, "Message");
    if (code is null) return ParsedS3Error(false, null, null);
    return ParsedS3Error(true, code, message is null ? "" : message);
}

unittest {
    auto xml = cast(const(ubyte)[]) (`<?xml version="1.0" encoding="UTF-8"?>` ~
        `<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message>` ~
        `<Key>csv.gz/does-not-exist.csv.gz</Key><RequestId>ABC</RequestId></Error>`);
    auto parsed = parseS3Error(xml);
    assert(parsed.valid);
    assert(parsed.code == "NoSuchKey");
    assert(parsed.message == "The specified key does not exist.");
}

unittest {
    auto parsed = parseS3Error(cast(const(ubyte)[]) "not xml at all");
    assert(!parsed.valid);
}

unittest {
    auto xml = cast(const(ubyte)[]) ("<Error><Code>NoSuchBucket</Code>" ~
        "<Message>The specified bucket does not exist</Message></Error>");
    auto parsed = parseS3Error(xml);
    assert(parsed.valid && parsed.code == "NoSuchBucket");
}
