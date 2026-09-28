/// lexcontent: standalone HTML main-content extraction (boilerplate removal)
/// and Markdown rendering, on a vendored, statically-linked Lexbor HTML5
/// parser. Extracted from scrubbed (schancel/scrubbed) issue #361; the
/// underlying extraction/rendering algorithm is unchanged from scrubbed's
/// `effects.html_main_content`/`effects.html_main_content_markdown`/
/// `effects.html_markdown` (issue #335 Slice 2), only the module paths and
/// package boundary are new.
///
/// `import lexcontent;` re-exports the small public surface most callers
/// need. Lower-level pieces (the HTML tree builder, the raw Lexbor FFI, the
/// byte-decoding helper) are available from their own
/// `lexcontent.html_tree`/`lexcontent.lexbor_ffi`/`lexcontent.decoding`
/// modules for callers who need them directly.
module lexcontent;

public import lexcontent.html_tree : HtmlTree, HtmlNode, HtmlNodeKind,
    HtmlAttribute, HtmlOutcome, HtmlFailure, HtmlFailureReason, parseHtml;
public import lexcontent.html_main_content : extractMainContent,
    MainContentResult, MainContentStatus, MainContentCandidate,
    HtmlMainContentOutputLimit;
public import lexcontent.html_main_content_markdown :
    extractMainContentMarkdown, MainContentMarkdownResult;
public import lexcontent.html_markdown : renderMarkdown, renderMarkdownFrom,
    HtmlMarkdownOutputLimit;
