# Mechanical HTML-to-Markdown converter

`effects.html_markdown.renderMarkdown(const ref HtmlTree)` converts the
D-owned selected tree from `effects.html_tree.parseHtml` to an owned UTF-8
string. It does not parse HTML, select main content, publish a file, or wire
`extract --format=markdown`; that CLI successor is separately reviewed.

The converter preserves selected visible text in document order and emits
one trailing newline for nonempty output. Whitespace in ordinary text is
collapsed to single spaces; block elements are separated by one blank line.
Markdown punctuation and literal `<`, `>`, `&` in ordinary text are escaped.
ASCII controls, including NUL, are omitted. `script`, `style`, `template`,
and the non-visible `head` subtree are omitted; unknown elements unwrap their
visible children. HTML parser repairs determine malformed tree structure;
the converter never synthesizes missing words.

V1 maps `h1`–`h6`, `p`, `br`, `em`/`i`, `strong`/`b`, `ul`, `ol`, `li`,
`blockquote`, `code`, `pre`, `a`, `img`, and tables. Nested lists use two-space
indentation. An ordered list uses a positive integer `start` attribute or
starts at 1; zero, negative, overflowed, and invalid starts use 1. Inline code
delimiter longer than its content's longest run, and fenced code chooses at
least three backticks, likewise longer than any run. Whitespace inside code
is retained, apart from CR normalization and omitted controls.

Tables deliberately do **not** claim GFM table layout. Each `tr` becomes a
plain `- ` row, with cells in source reading order separated by ` | `;
literal cell pipes are escaped. Header and data cells use the same policy.
Rowspan/colspan are not interpreted. Parser-repaired malformed rows follow
the selected tree's order. This policy retains text without inventing a
rectangular grid.

Links and images activate a target only for `http:`, `https:`, `mailto:`,
or relative references. Protocol-relative, backslash-leading, control,
whitespace, angle-bracket, overlong (more than 4096 bytes), and other-scheme
targets are rejected. Rejected links retain their visible label; rejected
images retain escaped alt text. No raw HTML is passed through.

The writer throws `HtmlMarkdownOutputLimit` before exceeding 4 MiB and
returns no partial string. The upstream parser separately caps raw input,
decoded input, tree depth/count, and selected observation. This is a logical
output-byte cap, not an exact peak-memory guarantee.

The release-active D check is `experiments/html_markdown/check.d`. After the
native static library is built by DUB, run:

```sh
ldc2 -O -release -Isource -of=/tmp/html-markdown-check \
  experiments/html_markdown/check.d source/effects/html_markdown.d \
  source/effects/html_tree.d source/effects/lexbor_ffi.d \
  source/text/decoding.d .dub/lexbor/liblexbor_static.a
/tmp/html-markdown-check
```

It checks exact output, repeat determinism, unsafe targets, malformed
structure, control handling, and output expansion past the cap. A later CLI
slice must prove atomic no-partial publication and unchanged tree-json behavior
against the shipping executable before issue #25 closes.
