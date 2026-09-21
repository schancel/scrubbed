/// Authored synthetic held-out examples, separate from quality module tests.
module quality.fixtures;

import domain.document : OutputName, SourceLocator;
import domain.shard_format : ShardDocument;

ShardDocument[] heldOut() {
    return [
        ShardDocument(SourceLocator("quality-heldout-v1", "authored", "empty"),
            OutputName("empty"), []),
        ShardDocument(SourceLocator("quality-heldout-v1", "authored", "repeat"),
            OutputName("repeat"), cast(ubyte[])"A\nA\nB".dup),
        ShardDocument(SourceLocator("quality-heldout-v1", "authored", "unicode"),
            OutputName("unicode"), cast(ubyte[])"é\uFFFD\n".dup),
        ShardDocument(SourceLocator("quality-heldout-v1", "authored", "invalid"),
            OutputName("invalid"), [cast(ubyte)0xff, 0]),
        ShardDocument(SourceLocator("quality-heldout-v1", "authored", "nul"),
            OutputName("nul"), cast(ubyte[])"a\0b\n".dup),
        ShardDocument(SourceLocator("quality-heldout-v1", "authored", "boundary"),
            OutputName("boundary"), cast(ubyte[])"abc\nabc\n".dup),
    ];
}
