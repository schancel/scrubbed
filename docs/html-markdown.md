# Mechanical HTML-to-Markdown converter

`effects.html_markdown.renderMarkdown(const ref HtmlTree)` converts the
D-owned selected tree from `effects.html_tree.parseHtml` to an owned UTF-8
string. It does not parse HTML or select main content. The self-registering
`effects.html_markdown_stage` consumes the bounded selected tree and exposes
`extract --format=markdown` through the same per-destination atomic route as
`tree-json`. Directory outputs append `.md`; explicit single-file paths are
used as supplied. A quarantined file retains its prior output and exit status
is 1; path or write failures are fatal exit 2. This is not a directory-wide
transaction.

The converter preserves selected visible text in document order and emits
one trailing newline for nonempty output. Whitespace in ordinary text is
collapsed to single spaces; block elements are separated by one blank line.
Markdown punctuation and literal `<`, `>`, `&` in ordinary text are escaped.
Unicode control and format characters, including NUL and bidi overrides, are
omitted from ordinary text, code, and alt text. `script`, `style`, `template`,
and the non-visible `head` subtree are omitted; unknown elements unwrap their
visible children. HTML parser repairs determine malformed tree structure;
the converter never synthesizes missing words.

V1 maps `h1`–`h6`, `p`, `br`, `em`/`i`, `strong`/`b`, `ul`, `ol`, `li`,
`blockquote`, `code`, `pre`, `a`, `img`, and tables. List continuations are
indented by the full marker width, preserving blank lines between paragraphs
inside an item. An ordered list uses a positive integer `start` attribute or
starts at 1; zero, negative, overflowed, and invalid starts use 1. Inline code
chooses a backtick delimiter longer than its content's longest run; inline
code is normalized to one line so it cannot break into active Markdown. Empty
inline code emits nothing. Fenced code chooses at least three backticks,
likewise longer than any run. Whitespace inside fenced code is retained,
apart from CR normalization and omitted controls.

Tables deliberately do **not** claim GFM table layout. Each `tr` becomes a
plain `- ` row, with cells in source reading order separated by ` | `;
literal cell pipes are escaped. Block whitespace inside a cell is flattened
to spaces, keeping all cell text on its row. Header and data cells use the
same policy.
Rowspan/colspan are not interpreted. Parser-repaired malformed rows follow
the selected tree's order. This policy retains text without inventing a
rectangular grid.

Links and images activate a target only for `http:`, `https:`, `mailto:`,
or relative references. Protocol-relative, backslash-leading, control,
whitespace, angle-bracket, overlong (more than 4096 bytes), and other-scheme
targets are rejected, including Unicode control and format characters.
Allowed destinations escape literal `&` as `&amp;` when written to Markdown,
so a Markdown parser's entity decoding cannot turn an apparently relative
target into an active scheme or alter a literal entity-looking path. Rejected
links retain their visible label; rejected images retain escaped alt text. No
raw HTML is passed through.

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
# If pandoc is installed, also prove the malicious inline-code golden
# stays inert after CommonMark parsing:
/tmp/html-markdown-check --commonmark
```

It checks exact output, repeat determinism, unsafe targets, malformed
structure, control handling, and output expansion past the cap. The shipping
binary is checked separately with `experiments/html_markdown/cli_check.d`:

```sh
dub build --build=release
ldc2 -O3 -release -of=.dub/html-markdown-cli-check experiments/html_markdown/cli_check.d
.dub/html-markdown-cli-check ./scrubbed
```

The actual-binary check covers exact Markdown output, malformed/unsafe input,
file and directory naming, quarantine, aliases, and a read-only-directory
sink-open failure with prior output and no temporary file. Nested ordered lists
with long `start` markers and repeated line breaks expand an admitted input
past 4 MiB; the stage reports `outputLimit` and preserves the prior output.
The existing HTML parser CLI checker pins unchanged `tree-json` bytes and
unknown-format behavior.
