# URL discovery value seam

`effects.web_url` owns the additive `web-url:v1` identity used by later
discovery and deduplication work. It accepts a caller-supplied HTTP(S) response
URL, an optional document base, and one selected reference. Resolution and
serialization use the repository's pinned Lexbor implementation; all returned
strings are copied into D-owned storage before native memory is released.

The fetch identity is the canonical absolute URL without a fragment. Default
ports are absent, host case, paths, IPv4/IPv6, and IDNA follow pinned Lexbor
serialization, and query bytes retain their parsed order and duplicates. The
separate fragment field distinguishes no fragment from an empty fragment.
`sameOrigin` compares the complete canonical scheme/host/effective-port origin.
It does not approximate same-site.

Every input and serialized URL is capped at 4096 bytes. Invalid UTF-8, Lexbor
validation errors, credentials, non-HTTP(S) schemes, native failures, and
oversized results produce only typed, content-free failures. Discovery evidence
contains the canonical response referrer, typed relation and attribute kinds,
DOM node ordinal, depth, and a lower-case SHA-256 digest of the raw attribute
value. It never retains that raw value.

This seam does not walk HTML, parse `srcset`, decide allowed domains or
one-hop admission, classify same-site, remove tracking parameters, normalize
query semantics, implement calendar/query traps, fetch content, or claim that
two query strings identify the same content. The known successor is #237,
whose persistence and deduplication must key the versioned canonical identity
rather than an unversioned display URL. No generic URI/plugin abstraction or
public-suffix database is introduced.

Build project dependencies, then compile and run the release-active checker:

```sh
dub build --compiler=ldc2 --build=release
ldc2 -i -I=source -O3 -release -enable-inlining \
  experiments/url_discovery/check.d .dub/lexbor/liblexbor_static.a \
  -of=/tmp/scrubbed-url-discovery-check
/tmp/scrubbed-url-discovery-check
```

Rollback is deletion of this module, checker, and document. No existing
consumer, stored record, or migration depends on the seam yet.
