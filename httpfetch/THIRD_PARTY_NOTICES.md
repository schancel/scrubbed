# Third-party notices

## Lexbor

`third_party/lexbor` vendors [Lexbor](https://github.com/lexbor/lexbor)'s
WHATWG URL parser, used by `httpfetch.web_url` for spec-compliant URL
resolution and canonicalization (the same code this package's `web_url.d`
originally used inside `scrubbed`). Lexbor is copyright 2018-2026 Alexander
Borisov and licensed under Apache 2.0. The complete upstream `LICENSE` and
`NOTICE` are bundled at `third_party/lexbor/LICENSE` and
`third_party/lexbor/NOTICE`.

Lexbor's numeric-conversion source includes BSD-style notices attributed to
NGINX, Inc.; F5, Inc.; Igor Sysoev; Dmitry Volyntsev; Alexander Borisov; and
Vadim Zhestikov, preserved unmodified in
`third_party/lexbor/source/lexbor/core/{diyfp,dtoa,strtod}.{c,h}`.

This package's own code (everything under `source/`) is MIT-licensed; see
`LICENSE`.
