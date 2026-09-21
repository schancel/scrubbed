/// Narrow ABI for the pinned Lexbor v3.0.0 source in third_party/lexbor.
/// Native pointers are never part of the public HTML-tree result.
module effects.lexbor_ffi;

version (OSX) {
    version (AArch64) {} else static assert(0,
        "Lexbor ABI is only verified for macOS arm64");
} else static assert(0, "Lexbor ABI is only verified for macOS arm64");

extern(C) {
    /// lxb_dom_node_t, source/lexbor/dom/interfaces/node.h.
    struct NativeNode {
        void* events; // lxb_dom_event_target_t
        size_t localName;
        size_t prefix;
        size_t ns;
        void* ownerDocument;
        NativeNode* next;
        NativeNode* prev;
        NativeNode* parent;
        NativeNode* firstChild;
        NativeNode* lastChild;
        void* user;
        int type;
    }

    /// lexbor_str_t, source/lexbor/core/str.h.
    struct NativeString {
        const(ubyte)* data;
        size_t length;
    }

    /// lxb_dom_text_t embeds lxb_dom_character_data_t at offset zero.
    struct NativeText {
        NativeNode node;
        NativeString data;
    }

    void* lxb_html_document_create();
    int lxb_html_document_parse(void* document, const(ubyte)* utf8, size_t length);
    void* lxb_html_document_destroy(void* document);
    const(ubyte)* lxb_dom_element_qualified_name(NativeNode* element, size_t* length);
    void* lxb_dom_element_first_attribute_noi(NativeNode* element);
    void* lxb_dom_element_next_attribute_noi(void* attribute);
    const(ubyte)* lxb_dom_attr_qualified_name(void* attribute, size_t* length);
    const(ubyte)* lxb_dom_attr_value_noi(void* attribute, size_t* length);
}

enum int elementNode = 1;
enum int textNode = 3;

static assert(NativeNode.sizeof == 96);
static assert(NativeNode.firstChild.offsetof == 64);
static assert(NativeNode.type.offsetof == 88);
static assert(NativeText.sizeof == 112);
static assert(NativeText.data.offsetof == 96);

unittest {
    auto document = lxb_html_document_create();
    assert(document !is null);
    scope(exit) lxb_html_document_destroy(document);
    const(ubyte)[] html = cast(const(ubyte)[]) "<p>ABI probe</p>";
    assert(lxb_html_document_parse(document, html.ptr, html.length) == 0);
    auto root = cast(NativeNode*) document;
    assert(root.firstChild !is null);
}
