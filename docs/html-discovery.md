# HTML link-discovery walker

`effects.html_discovery.discoverHtmlLinks` walks a complete, already-parsed
`effects.html_tree.HtmlTree` and turns selected element/attribute pairs into
`effects.web_url` discovery candidates. It is the first module that walks the
restricted HTML tree for link discovery; nothing before it did.

## Fixed v1 match table

Exactly these element/attribute pairs are matched. Nothing else is:

| Element             | Attribute | Relation          | Notes                                   |
|----------------------|-----------|-------------------|------------------------------------------|
| `a`                  | `href`    | hyperlink         |                                            |
| `link`               | `href`    | hyperlink         | Includes `rel=canonical`; `rel` is not otherwise inspected. |
| `img`                | `src`     | embeddedResource  |                                            |
| `source`             | `src`     | embeddedResource  |                                            |
| `img`, `source`      | `srcset`  | embeddedResource  | Parsed into one candidate per bounded entry; see below. |

Every accepted attribute value is handed to
`effects.web_url.discoverWebUrl(responseUrl, reference, relation, nodeOrdinal,
attribute, depth, documentBase)`. That function owns all malformed/
unsupported-scheme/credential-bearing rejection and all URL resolution and
canonicalization; this module reimplements none of it and trusts its typed
`WebUrlFailure` results exactly as given.

## `srcset`

`srcset` values are parsed with a bounded, ASCII-whitespace/comma tokenizer
kept local to this module: `maxSrcsetCandidatesPerAttribute` (64) caps how
many candidate-URL-plus-descriptor entries one attribute value can produce,
independent of the document-wide cap below. This is a pragmatic bounded
parse, not full HTML `srcset` conformance (for example it does not special-
case a comma embedded inside an unescaped URL). The descriptor (`1x`,
`480w`, ...) is parsed but not otherwise interpreted; only the candidate URL
is discovered.

## `<base>`

The first `base` element with an `href` attribute, in document order,
becomes `documentBase` for every subsequent resolution in the walk. A `base`
element without an `href` attribute is skipped in favor of a later one that
has one. An invalid or misleading base is not specially handled: every
attempted resolution against it surfaces `discoverWebUrl`'s own typed
`documentBase` failure, rather than this module silently falling back to "no
base."

## Scope policy (`DiscoveryScopePolicy`)

A versioned policy (`DiscoveryScopePolicyVersion.v1`) selects exactly one of
three variants, per the accepted owner decision deferring same-site
classification to a later slice:

- **`sameOrigin`** -- exact scheme/host/effective-port equality with the
  referring document, using `WebUrl.sameOrigin`.
- **`allowedDomain`** -- exact membership of the candidate's canonical
  `origin` in a caller-supplied allow-list (`allowedOrigins`). This is exact
  origin-string equality only: it does not parse bare hostnames, strip
  subdomains, or consult a public-suffix table.
- **`oneHopExternal`** -- admits any destination origin. It records that this
  walker intentionally does not restrict destination scope for a single hop
  away from an already in-scope document. Enforcing that no *further* hop is
  taken from an externally-discovered page is a decision that spans multiple
  documents and belongs to the frontier, not to a single-document walker.

No same-site (public-suffix-list-style) classifier exists in this module, in
whole or in part. It is deferred to a later slice by explicit owner decision
recorded on #239.

## Link-explosion protection

`maxDiscoveredLinksPerDocument` (4096) bounds the number of attempted
resolutions -- accepted, rejected, or out-of-scope -- per call. Once reached,
the walker stops scanning the tree immediately and reports `truncated`. A
caller may pass a smaller `maxLinks`.

This is the only trap heuristic in this slice. Cycles are not detected here:
the walker only ever extracts evidence from the document it is given and
never follows a reference, so a cyclic *reference graph* spanning multiple
documents cannot make it loop or choke; the frontier's existing permanent
duplicate-rejection property (exercised by #237/#251/#253) is what prevents
the crawl itself from cycling. Calendar and query-permutation traps are not
implemented: this slice names no such heuristic, so calendar-like and
query-varying links are discovered as ordinary, unfiltered candidates.

## Main-content independence

`discoverHtmlLinks` takes the complete `HtmlTree`, never a content-extraction
result. Main-content selection and link discovery are unrelated concerns in
this codebase: a subtree a hypothetical boilerplate/main-content selector
would reject (navigation, footer, ...) still yields its links here.

## Non-goals

Fetching, robots.txt decisions, JavaScript-rendered links, frontier/CLI
wiring, same-site classification (deferred, see above), deduplication across
documents (the frontier's job), and any claim that two differently-encoded
references to the same path identify the same content -- `effects.web_url`
already disclaims that, and this module inherits the disclaimer unchanged.

## Running the checker

```sh
dub build --compiler=ldc2 --build=release
ldc2 -i -I=source -O3 -release -enable-inlining \
  experiments/html_discovery/check.d .dub/lexbor/liblexbor_static.a \
  -of=/tmp/scrubbed-html-discovery-check
/tmp/scrubbed-html-discovery-check
```

Rollback is deletion of this module, checker, and document. No existing
consumer, stored record, or migration depends on this walker yet.
