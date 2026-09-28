/// Minimal parser for S3's real `ListObjectsV2` response shape:
///
///   <?xml version="1.0" encoding="UTF-8"?>
///   <ListBucketResult>
///     <IsTruncated>true</IsTruncated>
///     <Contents>
///       <Key>a/b.txt</Key>
///       <LastModified>2024-01-02T03:04:05.000Z</LastModified>
///       <ETag>"abc123"</ETag>
///       <Size>1234</Size>
///     </Contents>
///     ...
///     <NextContinuationToken>...</NextContinuationToken>
///   </ListBucketResult>
///
/// Deliberately not a general-purpose XML parser -- same rationale as
/// `s3lite.xml_error`: S3's own `ListBucketResult` shape is small, flat (one
/// level of repeated `<Contents>` elements, no nested `<Contents>` inside
/// `<Contents>`), and well-known, so a targeted tag extractor keeps this
/// package at zero dependencies instead of pulling in a real XML library.
module s3lite.xml_list;

import std.conv : to;
import std.string : indexOf;

/// One object entry from a `ListObjectsV2` page.
struct S3Object {
    string key;
    size_t size;
    string etag;
    string lastModified;
}

struct ParsedListPage {
    bool valid;              // true if this looked like a well-formed <ListBucketResult>
    S3Object[] objects;
    bool isTruncated;
    string nextContinuationToken; // "" if isTruncated is false, or S3 omitted it
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

/// Extracts the first `<tag>...</tag>` at or after `from` within `xml`,
/// scoped to end no later than `limit` (so a top-level tag search never
/// reaches into a later sibling's element by accident). Returns null (not
/// found) via `found` rather than throwing -- callers decide what a missing
/// optional tag means.
private string extractTagIn(string xml, string tag, size_t from, size_t limit, out bool found) {
    auto open = "<" ~ tag ~ ">";
    auto close = "</" ~ tag ~ ">";
    auto start = xml.indexOf(open, from);
    if (start < 0 || cast(size_t) start >= limit) { found = false; return null; }
    start += open.length;
    auto end = xml.indexOf(close, start);
    if (end < 0 || cast(size_t) end > limit) { found = false; return null; }
    found = true;
    return decodeEntities(xml[start .. end]);
}

/// Parses one `ListObjectsV2` XML response body into its object entries plus
/// pagination state. Returns `valid == false` (not an exception) if the body
/// doesn't contain a recognizable `<ListBucketResult>` root -- callers treat
/// that the same way `s3lite.xml_error`'s callers treat an unparseable error
/// body: a typed `malformedResponse`, not a crash.
ParsedListPage parseListObjectsV2(scope const(ubyte)[] body_) {
    auto text = cast(string) body_.idup;
    if (text.indexOf("<ListBucketResult") < 0)
        return ParsedListPage(false);

    bool found;
    auto truncatedText = extractTagIn(text, "IsTruncated", 0, text.length, found);
    bool isTruncated = found && truncatedText == "true";

    string nextToken;
    if (isTruncated)
        nextToken = extractTagIn(text, "NextContinuationToken", 0, text.length, found);
    if (nextToken is null) nextToken = "";

    S3Object[] objects;
    size_t pos = 0;
    while (true) {
        auto openTag = "<Contents>";
        auto closeTag = "</Contents>";
        auto start = text.indexOf(openTag, pos);
        if (start < 0) break;
        auto contentStart = start + openTag.length;
        auto end = text.indexOf(closeTag, contentStart);
        if (end < 0) break; // malformed trailing <Contents> with no close -- stop, keep what parsed so far

        bool keyFound, sizeFound;
        auto key = extractTagIn(text, "Key", contentStart, end, keyFound);
        auto sizeText = extractTagIn(text, "Size", contentStart, end, sizeFound);
        auto etag = extractTagIn(text, "ETag", contentStart, end, found);
        auto lastModified = extractTagIn(text, "LastModified", contentStart, end, found);

        if (keyFound) {
            size_t size = 0;
            if (sizeFound) {
                try size = sizeText.to!size_t;
                catch (Exception) size = 0;
            }
            objects ~= S3Object(key, size, etag is null ? "" : etag,
                lastModified is null ? "" : lastModified);
        }

        pos = end + closeTag.length;
    }

    return ParsedListPage(true, objects, isTruncated, nextToken);
}

unittest {
    auto xml = cast(const(ubyte)[]) (
        `<?xml version="1.0" encoding="UTF-8"?>` ~
        `<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` ~
        `<Name>examplebucket</Name><Prefix></Prefix><KeyCount>2</KeyCount>` ~
        `<MaxKeys>2</MaxKeys><IsTruncated>true</IsTruncated>` ~
        `<Contents><Key>a.txt</Key><LastModified>2024-01-02T03:04:05.000Z</LastModified>` ~
        `<ETag>&quot;abc123&quot;</ETag><Size>10</Size><StorageClass>STANDARD</StorageClass></Contents>` ~
        `<Contents><Key>b/c.txt</Key><LastModified>2024-01-03T00:00:00.000Z</LastModified>` ~
        `<ETag>&quot;def456&quot;</ETag><Size>2048</Size><StorageClass>STANDARD</StorageClass></Contents>` ~
        `<NextContinuationToken>token-1</NextContinuationToken>` ~
        `</ListBucketResult>`);
    auto parsed = parseListObjectsV2(xml);
    assert(parsed.valid);
    assert(parsed.objects.length == 2);
    assert(parsed.objects[0].key == "a.txt");
    assert(parsed.objects[0].size == 10);
    assert(parsed.objects[0].etag == `"abc123"`);
    assert(parsed.objects[1].key == "b/c.txt");
    assert(parsed.objects[1].size == 2048);
    assert(parsed.isTruncated);
    assert(parsed.nextContinuationToken == "token-1");
}

unittest {
    // Final page: IsTruncated=false, no NextContinuationToken at all.
    auto xml = cast(const(ubyte)[]) (
        `<ListBucketResult><IsTruncated>false</IsTruncated>` ~
        `<Contents><Key>only.txt</Key><ETag>"z"</ETag><Size>1</Size></Contents>` ~
        `</ListBucketResult>`);
    auto parsed = parseListObjectsV2(xml);
    assert(parsed.valid);
    assert(!parsed.isTruncated);
    assert(parsed.nextContinuationToken == "");
    assert(parsed.objects.length == 1 && parsed.objects[0].key == "only.txt");
}

unittest {
    // Empty bucket/prefix: valid root, zero <Contents> entries.
    auto xml = cast(const(ubyte)[]) (
        `<ListBucketResult><IsTruncated>false</IsTruncated><KeyCount>0</KeyCount></ListBucketResult>`);
    auto parsed = parseListObjectsV2(xml);
    assert(parsed.valid);
    assert(parsed.objects.length == 0);
    assert(!parsed.isTruncated);
}

unittest {
    auto parsed = parseListObjectsV2(cast(const(ubyte)[]) "not xml at all");
    assert(!parsed.valid);
}
