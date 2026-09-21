# Third-party notices

## ftfy

The mojibake detector design and selected regression-test inputs in
`source/filters/mojibake.d` are adapted from the public test suite and badness
model of [ftfy](https://github.com/rspeer/python-ftfy), copyright 2023 Robyn
Speer, licensed under the Apache License 2.0.

scrubbed's implementation is independently written in D and currently covers
only reversible Latin-1 and Windows-1252/UTF-8 round trips. It is not a full
port of ftfy.

The upstream ftfy copyright/license notice is included at
`third_party/ftfy-LICENSE.txt`, and the complete Apache License 2.0 terms are
included at `third_party/Apache-2.0.txt`. Corpus results use upstream revision
`74dd0452b48286a3770013b3a02755313bd5575e`.

## software-factory

The vendored workflow skills under `.agents/` come from
[software-factory](https://github.com/schancel/software-factory), copyright
2026 Shammah Chancellor, licensed under the MIT License. A copy is included at
`third_party/software-factory-LICENSE.txt`. The pristine `.agents/.factory-base`
snapshot is upstream revision `06aeca7fe1f6fb6f3bffe70ff8fe340a9fcfb54e`;
the active copy adds a local maintainer-label authorization gate for public
GitHub issue queues and fetches GitHub's full supported dependency count.
