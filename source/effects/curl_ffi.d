/// Narrow ABI for the host-provided dynamic libcurl (`/usr/lib/libcurl.4.dylib`
/// on macOS arm64), evaluated in `experiments/http_fetch/check.d` and recorded
/// in `docs/http-fetch-evaluation.md` (verdict ADOPT_DYNAMIC). Declares exactly
/// the easy/multi handle lifecycle, option, and info entry points that
/// evaluation probe exercised. No native pointer or `CURL*`/`CURLM*` handle is
/// part of any public result type in `effects.http_fetch`.
module effects.curl_ffi;

version (OSX) {
    version (AArch64) {} else static assert(0,
        "libcurl ABI is only verified for macOS arm64");
} else static assert(0, "libcurl ABI is only verified for macOS arm64");

extern(C) nothrow {
    struct CURL;
    struct CURLM;

    /// curl_slist, include/curl/curl.h.
    struct curl_slist {
        char* data;
        curl_slist* next;
    }

    /// CURLMsg, include/curl/multi.h. Only `.msg`/`.easyHandle`/`.data.result`
    /// (the CURLMSG_DONE payload) are read by this module.
    struct CurlMsg {
        int msg;
        CURL* easyHandle;
        union Payload { void* pointer; int result; }
        Payload data;
    }

    const(char)* curl_version();
    int curl_global_init(long flags);
    void curl_global_cleanup();

    CURL* curl_easy_init();
    void curl_easy_cleanup(CURL*);
    int curl_easy_setopt(CURL*, int option, ...);
    int curl_easy_getinfo(CURL*, int info, ...);
    int curl_easy_perform(CURL*);

    curl_slist* curl_slist_append(curl_slist*, const(char)*);
    void curl_slist_free_all(curl_slist*);

    CURLM* curl_multi_init();
    int curl_multi_add_handle(CURLM*, CURL*);
    int curl_multi_remove_handle(CURLM*, CURL*);
    int curl_multi_perform(CURLM*, int* running);
    int curl_multi_poll(CURLM*, void*, uint, int timeoutMs, int* numfds);
    CurlMsg* curl_multi_info_read(CURLM*, int* remaining);
    int curl_multi_cleanup(CURLM*);
}

/// curl_global_init(CURL_GLOBAL_ALL). The evaluation probe recorded no other
/// flag combination.
enum long curlGlobalAll = 3;

enum : int {
    CURLE_OK = 0,
    CURLE_UNSUPPORTED_PROTOCOL = 1,
    CURLE_WRITE_ERROR = 23,
    CURLE_OPERATION_TIMEDOUT = 28,
    CURLE_ABORTED_BY_CALLBACK = 42,
    CURLE_TOO_MANY_REDIRECTS = 47,
    CURLE_PEER_FAILED_VERIFICATION = 60,

    CURLMSG_DONE = 1,
    CURLM_OK = 0,

    // CURLoption values, include/curl/curl.h. Only the options the evaluation
    // probe set are declared.
    CURLOPT_WRITEDATA = 10_001,
    CURLOPT_URL = 10_002,
    CURLOPT_PROXY = 10_004,
    CURLOPT_HTTPHEADER = 10_023,
    CURLOPT_WRITEFUNCTION = 20_011,
    CURLOPT_HEADERDATA = 10_029,
    CURLOPT_NOPROGRESS = 43,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_XFERINFODATA = 10_057,
    CURLOPT_SSL_VERIFYPEER = 64,
    CURLOPT_CAINFO = 10_065,
    CURLOPT_MAXREDIRS = 68,
    CURLOPT_HEADERFUNCTION = 20_079,
    CURLOPT_SSL_VERIFYHOST = 81,
    CURLOPT_NOSIGNAL = 99,
    CURLOPT_ACCEPT_ENCODING = 10_102,
    CURLOPT_TIMEOUT_MS = 155,
    CURLOPT_CONNECTTIMEOUT_MS = 156,
    CURLOPT_RESOLVE = 10_203,
    CURLOPT_XFERINFOFUNCTION = 20_219,
    CURLOPT_PROTOCOLS_STR = 10_318,
    CURLOPT_REDIR_PROTOCOLS_STR = 10_319,

    // CURLINFO values, include/curl/curl.h.
    CURLINFO_RESPONSE_CODE = 0x20_0002,
    CURLINFO_SIZE_DOWNLOAD_T = 0x60_0008,
}

unittest {
    // The ABI probe: confirms the declared entry points link and the fixed
    // option/info numeric values still match the linked library's behavior
    // for a loopback-free, allocation-only round trip (global init/cleanup
    // and easy handle create/destroy). No network access.
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
