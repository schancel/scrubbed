/// Streaming parser for S3's `ListObjectsV2` response:
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
/// The body is fed in as it arrives, in pieces of any size. Each complete
/// `<Contents>` element is handed to a callback as views into the caller's
/// buffer and then discarded, so the memory needed is that of the largest
/// single entry -- not of the page, and not of the listing. Nothing is
/// allocated.
///
/// Not a general XML parser, for the same reason as `s3lite.xml_error`: the
/// shape is flat and well known (repeated `<Contents>` at one level, never
/// nested).
module s3lite.xml_list;

import s3lite.fixed : indexOf, parseUnsigned, startsWith;
import s3lite.xml_text : decodeEntitiesInPlace, elementText;

/// One listing entry. The slices point into the caller's entry buffer and
/// are valid only until the callback returns; copy what must be kept.
struct S3ObjectView {
    const(char)[] key;
    ulong size;
    const(char)[] etag;         /// as S3 sends it, quotes included
    const(char)[] lastModified; /// ISO 8601, as S3 sends it
}

/// Receives each entry in listing order. Returning false stops the listing.
alias ListEntryCallback = bool delegate(scope ref const S3ObjectView entry) @nogc nothrow;

/// An entry buffer must hold the largest single `<Contents>` element (or
/// continuation-token element) of a response. S3 keys are at most 1024
/// bytes, and a byte can take up to six when escaped, so 8 KiB covers the
/// worst case; typical entries are a few hundred bytes.
enum size_t recommendedListEntryBuffer = 8 * 1024;
/// Smallest entry buffer `ListPageParser` accepts.
enum size_t minListEntryBuffer = 256;

enum ListFeed {
    more,          /// chunk consumed; feed the next one
    stopped,       /// the callback returned false
    entryTooLarge, /// one element does not fit the entry buffer
}

struct ListPageParser {
    private char[] buf;
    private size_t fill;
    private char[] tokenBuf;
    private size_t tokenLen;

    bool sawRoot;        /// a `<ListBucketResult>` element was seen
    bool isTruncated;
    bool tokenTooLarge;  /// the continuation token did not fit `tokenStorage`
    ulong entries;       /// entries delivered so far

@nogc nothrow:

    /// `entryBuffer` is working memory; `tokenStorage` receives the
    /// decoded `NextContinuationToken`. Both are borrowed while the parser
    /// is in use.
    this(char[] entryBuffer, char[] tokenStorage) pure {
        buf = entryBuffer;
        tokenBuf = tokenStorage;
    }

    /// The page's `NextContinuationToken`, "" if it had none.
    const(char)[] nextToken() const return pure { return tokenBuf[0 .. tokenLen]; }

    /// Feeds the next piece of the response body.
    ListFeed feed(scope const(ubyte)[] chunk, scope ListEntryCallback onEntry) {
        auto text = cast(const(char)[]) chunk;
        while (text.length) {
            if (fill == buf.length) return ListFeed.entryTooLarge;
            immutable room = buf.length - fill;
            immutable n = text.length < room ? text.length : room;
            buf[fill .. fill + n] = text[0 .. n];
            fill += n;
            text = text[n .. $];

            bool stopped;
            immutable consumed = scan(onEntry, stopped);
            if (stopped) return ListFeed.stopped;
            if (consumed) {
                import core.stdc.string : memmove;
                memmove(buf.ptr, buf.ptr + consumed, fill - consumed);
                fill -= consumed;
            }
            // Full with nothing consumable: one element is larger than the buffer.
            if (fill == buf.length) return ListFeed.entryTooLarge;
        }
        return ListFeed.more;
    }

    /// Handles every complete element in the buffer; returns how many
    /// leading bytes are finished with.
    private size_t scan(scope ListEntryCallback onEntry, out bool stopped) {
        static immutable string[3] wanted = ["Contents", "IsTruncated", "NextContinuationToken"];
        static immutable string[3] closers = ["</Contents>", "</IsTruncated>", "</NextContinuationToken>"];

        auto data = buf[0 .. fill];
        size_t pos = 0;
        while (true) {
            immutable lt = indexOf(data, '<', pos);
            if (lt < 0) return fill;
            immutable gt = indexOf(data, '>', lt + 1);
            if (gt < 0) return lt; // tag not complete yet
            auto name = data[lt + 1 .. gt];

            int which = -1;
            foreach (i, w; wanted) if (name == w) which = cast(int) i;
            if (which < 0) {
                if (startsWith(name, "ListBucketResult") && (name.length == 16 || name[16] == ' ' ||
                        name[16] == '\t' || name[16] == '\r' || name[16] == '\n' || name[16] == '/'))
                    sawRoot = true;
                pos = gt + 1;
                continue;
            }

            immutable close = indexOf(data, closers[which], gt + 1);
            if (close < 0) return lt; // element not complete yet
            auto content = data[gt + 1 .. close];
            pos = close + closers[which].length;

            final switch (which) {
                case 0:
                    if (!deliver(content, onEntry)) { stopped = true; return pos; }
                    break;
                case 1:
                    isTruncated = content == "true";
                    break;
                case 2:
                    auto token = decodeEntitiesInPlace(content);
                    if (token.length > tokenBuf.length) tokenTooLarge = true;
                    else {
                        tokenBuf[0 .. token.length] = token[];
                        tokenLen = token.length;
                    }
                    break;
            }
        }
    }

    private bool deliver(char[] content, scope ListEntryCallback onEntry) {
        bool keyFound, sizeFound, etagFound, modifiedFound;
        // Locate every field before decoding any: decoding rewrites bytes
        // in place, and the fields do not overlap.
        auto key = elementText(content, "Key", 0, content.length, keyFound);
        auto sizeText = elementText(content, "Size", 0, content.length, sizeFound);
        auto etag = elementText(content, "ETag", 0, content.length, etagFound);
        auto modified = elementText(content, "LastModified", 0, content.length, modifiedFound);
        if (!keyFound) return true; // not an object entry; skip it

        S3ObjectView view;
        view.key = decodeEntitiesInPlace(key);
        if (sizeFound && !parseUnsigned(sizeText, view.size)) view.size = 0;
        if (etagFound) view.etag = decodeEntitiesInPlace(etag);
        if (modifiedFound) view.lastModified = decodeEntitiesInPlace(modified);
        entries++;
        return onEntry is null ? true : onEntry(view);
    }
}

version(unittest) {
    private struct Seen {
        char[256] keys = 0;
        size_t keyLen;
        ulong sizes;
        char[64] lastEtag = 0;
        size_t etagLen;
        size_t stopAfter = size_t.max;
        size_t count;

        bool take(scope ref const S3ObjectView e) @nogc nothrow {
            keys[keyLen .. keyLen + e.key.length] = e.key[];
            keyLen += e.key.length;
            keys[keyLen++] = '|';
            sizes += e.size;
            lastEtag[0 .. e.etag.length] = e.etag[];
            etagLen = e.etag.length;
            return ++count < stopAfter;
        }
    }

    private immutable twoEntries =
        `<?xml version="1.0" encoding="UTF-8"?>` ~
        `<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` ~
        `<Name>examplebucket</Name><Prefix></Prefix>` ~
        `<NextContinuationToken>token-1</NextContinuationToken><KeyCount>2</KeyCount>` ~
        `<MaxKeys>2</MaxKeys><IsTruncated>true</IsTruncated>` ~
        `<Contents><Key>a.txt</Key><LastModified>2024-01-02T03:04:05.000Z</LastModified>` ~
        `<ETag>&quot;abc123&quot;</ETag><Size>10</Size><StorageClass>STANDARD</StorageClass></Contents>` ~
        `<Contents><Key>b/c&amp;d.txt</Key><LastModified>2024-01-03T00:00:00.000Z</LastModified>` ~
        `<ETag>&quot;def456&quot;</ETag><Size>2048</Size><StorageClass>STANDARD</StorageClass></Contents>` ~
        `</ListBucketResult>`;
}

@nogc nothrow unittest {
    // Whole body in one piece.
    char[512] entryBuffer;
    char[64] token;
    auto parser = ListPageParser(entryBuffer[], token[]);
    Seen seen;
    assert(parser.feed(cast(const(ubyte)[]) twoEntries, &seen.take) == ListFeed.more);
    assert(parser.sawRoot && parser.isTruncated && parser.nextToken == "token-1");
    assert(parser.entries == 2 && seen.keys[0 .. seen.keyLen] == "a.txt|b/c&d.txt|");
    assert(seen.sizes == 2058 && seen.lastEtag[0 .. seen.etagLen] == `"def456"`);
}

@nogc nothrow unittest {
    // The same body one byte at a time, through a buffer far smaller than
    // the body: every tag and element straddles a feed boundary.
    char[minListEntryBuffer] entryBuffer;
    char[64] token;
    assert(twoEntries.length > entryBuffer.length);
    auto parser = ListPageParser(entryBuffer[], token[]);
    Seen seen;
    foreach (i; 0 .. twoEntries.length)
        assert(parser.feed(cast(const(ubyte)[]) twoEntries[i .. i + 1], &seen.take) == ListFeed.more);
    assert(parser.sawRoot && parser.isTruncated && parser.nextToken == "token-1");
    assert(seen.keys[0 .. seen.keyLen] == "a.txt|b/c&d.txt|" && seen.sizes == 2058);
}

@nogc nothrow unittest {
    // Final page, empty page, and a body that is not a listing at all.
    char[512] entryBuffer;
    char[64] token;
    Seen seen;
    auto last = ListPageParser(entryBuffer[], token[]);
    last.feed(cast(const(ubyte)[]) (`<ListBucketResult><IsTruncated>false</IsTruncated>` ~
        `<Contents><Key>only.txt</Key><ETag>"z"</ETag><Size>1</Size></Contents></ListBucketResult>`),
        &seen.take);
    assert(last.sawRoot && !last.isTruncated && last.nextToken == "" && last.entries == 1);

    auto empty = ListPageParser(entryBuffer[], token[]);
    empty.feed(cast(const(ubyte)[])
        `<ListBucketResult><IsTruncated>false</IsTruncated><KeyCount>0</KeyCount></ListBucketResult>`, null);
    assert(empty.sawRoot && empty.entries == 0);

    auto junk = ListPageParser(entryBuffer[], token[]);
    assert(junk.feed(cast(const(ubyte)[]) "not xml at all", null) == ListFeed.more && !junk.sawRoot);
}

@nogc nothrow unittest {
    // The callback can stop the listing; an entry that cannot fit is an
    // error rather than a silent skip; so is a token that cannot fit.
    char[512] entryBuffer;
    char[64] token;
    Seen seen;
    seen.stopAfter = 1;
    auto parser = ListPageParser(entryBuffer[], token[]);
    assert(parser.feed(cast(const(ubyte)[]) twoEntries, &seen.take) == ListFeed.stopped);
    assert(seen.count == 1);

    char[minListEntryBuffer] small;
    auto tight = ListPageParser(small[], token[]);
    static immutable char[300] longKey = 'k';
    assert(tight.feed(cast(const(ubyte)[]) "<ListBucketResult><Contents><Key>", null) == ListFeed.more);
    assert(tight.feed(cast(const(ubyte)[]) longKey[], null) == ListFeed.entryTooLarge);

    char[4] tinyToken;
    auto noRoom = ListPageParser(entryBuffer[], tinyToken[]);
    noRoom.feed(cast(const(ubyte)[]) "<NextContinuationToken>too-long</NextContinuationToken>", null);
    assert(noRoom.tokenTooLarge && noRoom.nextToken == "");
}
