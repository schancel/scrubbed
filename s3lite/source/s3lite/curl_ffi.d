/// Narrow FFI binding to the host-provided dynamic libcurl, following the
/// same `extern(C)` shape as the parent `scrubbed` repository's own
/// `source/effects/curl_ffi.d` (issue #46's own precedent for this kind of
/// binding), but written fresh here as this package's own code -- this
/// package does not import scrubbed's module or link against anything in
/// scrubbed's own tree.
///
/// Declares only the easy-handle entry points `s3lite.curl_transport` needs:
/// a blocking exchange with custom request headers, a pulled request body,
/// and pushed response headers and body. No multi-handle/async machinery.
/// Every entry point is `@nogc nothrow`: libcurl is C and neither throws nor
/// touches the D collector.
module s3lite.curl_ffi;

extern(C) @nogc nothrow {
    struct CURL;

    /// curl_slist, include/curl/curl.h.
    struct curl_slist {
        char* data;
        curl_slist* next;
    }

    const(char)* curl_version();
    int curl_global_init(long flags);
    void curl_global_cleanup();

    CURL* curl_easy_init();
    void curl_easy_cleanup(CURL*);
    int curl_easy_setopt(CURL*, int option, ...);
    int curl_easy_getinfo(CURL*, int info, ...);
    int curl_easy_perform(CURL*);
    const(char)* curl_easy_strerror(int code);

    curl_slist* curl_slist_append(curl_slist*, const(char)*);
    void curl_slist_free_all(curl_slist*);
}

/// curl_global_init(CURL_GLOBAL_ALL). Matches scrubbed's own evaluated flag
/// value (`effects.curl_ffi.curlGlobalAll`).
enum long curlGlobalAll = 3;

enum : int {
    CURLE_OK = 0,

    // CURLoption values, include/curl/curl.h. Only the options this module
    // actually uses are declared, same convention as scrubbed's own binding.
    CURLOPT_WRITEDATA = 10_001,
    CURLOPT_URL = 10_002,
    CURLOPT_READDATA = 10_009,
    CURLOPT_HTTPHEADER = 10_023,
    CURLOPT_WRITEFUNCTION = 20_011,
    CURLOPT_READFUNCTION = 20_012,
    CURLOPT_HEADERDATA = 10_029,
    CURLOPT_LOW_SPEED_LIMIT = 19,
    CURLOPT_LOW_SPEED_TIME = 20,
    CURLOPT_NOPROGRESS = 43,
    CURLOPT_NOBODY = 44,
    CURLOPT_UPLOAD = 46,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_SSL_VERIFYPEER = 64,
    CURLOPT_CAINFO = 10_065,
    CURLOPT_MAXREDIRS = 68,
    CURLOPT_HEADERFUNCTION = 20_079,
    CURLOPT_HTTPGET = 80,
    CURLOPT_SSL_VERIFYHOST = 81,
    CURLOPT_NOSIGNAL = 99,
    CURLOPT_TIMEOUT_MS = 155,
    CURLOPT_CONNECTTIMEOUT_MS = 156,
    CURLOPT_CUSTOMREQUEST = 10_036,
    CURLOPT_PATH_AS_IS = 234,
    CURLOPT_SEEKDATA = 10_168,
    CURLOPT_SEEKFUNCTION = 20_167,
    CURLOPT_RESOLVE = 10_203,
    CURLOPT_PROTOCOLS_STR = 10_318,
    CURLOPT_REDIR_PROTOCOLS_STR = 10_319,
    CURLOPT_INFILESIZE_LARGE = 30_115,

    // CURLINFO values, include/curl/curl.h.
    CURLINFO_RESPONSE_CODE = 0x20_0002,

    // Callback return values, include/curl/curl.h.
    CURL_SEEKFUNC_OK = 0,
    CURL_SEEKFUNC_FAIL = 1,
}

/// Returned by a read callback to abandon the transfer.
enum size_t CURL_READFUNC_ABORT = 0x1000_0000;

unittest {
    // ABI smoke test: the declared entry points link and the fixed
    // option/info numeric values still match the linked library's behavior
    // for an allocation-only round trip. No network access.
    assert(curl_global_init(curlGlobalAll) == CURLE_OK);
    scope(exit) curl_global_cleanup();
    auto easy = curl_easy_init();
    assert(easy !is null);
    scope(exit) curl_easy_cleanup(easy);
    auto urlz = "http://127.0.0.1:1\0";
    assert(curl_easy_setopt(easy, CURLOPT_URL, urlz.ptr) == CURLE_OK);
    assert(curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L) == CURLE_OK);
    assert(curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L) == CURLE_OK);
}
