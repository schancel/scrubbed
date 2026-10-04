/// Parser for S3's REST error response:
///
///   <?xml version="1.0" encoding="UTF-8"?>
///   <Error><Code>NoSuchKey</Code><Message>...</Message>...</Error>
///
/// Not a general XML parser: S3's error body is a small, flat, well-known
/// tag set, so a targeted extractor is enough and keeps the package free of
/// dependencies. The result carries its text inline, so parsing allocates
/// nothing and the result outlives the body it was read from.
module s3lite.xml_error;

import s3lite.fixed : InlineText, indexOf;
import s3lite.xml_text : decodeEntitiesTo, elementText;

/// Longest `<Code>` and `<Message>` kept; longer text is cut and flagged
/// (`InlineText.truncated`).
enum size_t maxErrorCodeBytes = 64;
/// ditto
enum size_t maxErrorMessageBytes = 256;

struct ParsedS3Error {
    bool valid; /// true if the body held an `<Error>` element with a `<Code>`
    InlineText!maxErrorCodeBytes code;       /// e.g. "NoSuchKey", "AccessDenied"
    InlineText!maxErrorMessageBytes message; /// "" if S3 sent none
}

/// Parses an S3 error body. `valid == false` means the body is not a
/// recognisable `<Error>`; callers treat that as a malformed response.
ParsedS3Error parseS3Error(scope const(ubyte)[] body_) @nogc nothrow pure {
    auto text = cast(const(char)[]) body_;
    ParsedS3Error parsed;
    if (indexOf(text, "<Error>") < 0 && indexOf(text, "<Error ") < 0) return parsed;
    bool found;
    auto code = elementText(text, "Code", 0, text.length, found);
    if (!found) return parsed;
    decodeEntitiesTo(code, parsed.code);
    auto message = elementText(text, "Message", 0, text.length, found);
    if (found) decodeEntitiesTo(message, parsed.message);
    parsed.valid = true;
    return parsed;
}

@nogc nothrow pure unittest {
    static immutable xml = `<?xml version="1.0" encoding="UTF-8"?>` ~
        `<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message>` ~
        `<Key>csv.gz/does-not-exist.csv.gz</Key><RequestId>ABC</RequestId></Error>`;
    auto parsed = parseS3Error(cast(const(ubyte)[]) xml);
    assert(parsed.valid);
    assert(parsed.code[] == "NoSuchKey");
    assert(parsed.message[] == "The specified key does not exist.");
}

unittest {
    assert(!parseS3Error(cast(const(ubyte)[]) "not xml at all").valid);
    assert(!parseS3Error(cast(const(ubyte)[]) "<Error><Message>no code</Message></Error>").valid);
}

unittest {
    auto parsed = parseS3Error(cast(const(ubyte)[]) ("<Error><Code>NoSuchBucket</Code>" ~
        "<Message>The bucket &quot;b&amp;c&quot; does not exist</Message></Error>"));
    assert(parsed.valid && parsed.code[] == "NoSuchBucket");
    assert(parsed.message[] == `The bucket "b&c" does not exist`);
}
