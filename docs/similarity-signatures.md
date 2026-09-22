# Similarity signatures, first slice

`domain.similarity_signature.similaritySignatures` accepts a typed `DocumentId`
and caller-selected UTF-8 content of at most 1 MiB. It does not read C01
shards or C04 overlays, which store opaque bytes. The caller must choose a
text view; malformed UTF-8 is refused with `similarity signature: invalid UTF-8`.
No source or overlay is modified. This optional domain result is an input for
the separately reviewed disk-backed bucket successor, not a durable record or
a duplicate decision.

The frozen profile is `byte-shingle-minhash:v1`. ASCII `A`–`Z` becomes lowercase;
each run of ASCII whitespace (`U+0009`–`U+000D` or space) becomes one space,
including at either edge. No Unicode case folding, normalization, tokenization,
or language processing occurs. Minhash consumes five-byte sliding shingles
over the resulting UTF-8 bytes. Its 64 lanes use 64-bit FNV-1a with a frozen
SplitMix64 lane seed schedule; each lane is the minimum shingle hash. A band key
is 64-bit FNV-1a over its one-byte band ordinal and four lane values, each
encoded little-endian, yielding 16 position-separated keys. Arithmetic wraps
modulo 2^64. Inputs shorter than five normalized
bytes abstain and have no candidate keys.

The document gets one signature. Segments cover non-overlapping normalized
byte ranges with a 4096-byte target: a boundary moves backward if it would
split a UTF-8 code point. The final segment may be shorter. Each result carries
the typed document ID, a segment flag and zero-based ordinal, fixed-size lane
and band arrays, and profile version. A caller must distinguish document keys
from segment keys and include this profile plus normalization and segment rule
in any future artifact identity. A matching band is only a candidate signal;
there is no recall guarantee, probability assertion, cluster, representative,
or final policy here.

The input cap and non-expanding normalization bound memory to one input plus
one normalized copy and at most 257 fixed-size segment signatures. No corpus
state is retained. Rollback is removal of this optional module, checker, and
document; immutable source data is untouched.
