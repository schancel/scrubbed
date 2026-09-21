# Third-party notices

## WHATWG HTML named character references

`source/filters/entities_data.d` is a generated D representation of the
[WHATWG HTML Standard's named character references](https://html.spec.whatwg.org/entities.json)
(2,231 names). The pinned JSON bytes have SHA-256
`d741d877ac77c4194c4ad526b5b4a19aef8dfe411ab840a466891cdbb9f362e6`;
the generator source was fetched on 2026-09-20. The applicable upstream
[LICENSE](https://github.com/whatwg/html/blob/24434a064e09609a0c91342dceb34ebaa689b2b8/LICENSE)
at revision `24434a064e09609a0c91342dceb34ebaa689b2b8` says portions
incorporated into source code are licensed under BSD 3-Clause.
The generated data is incorporated into D source code and has not been
modified beyond format conversion.

Copyright © WHATWG (Apple, Google, Mozilla, Microsoft).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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
