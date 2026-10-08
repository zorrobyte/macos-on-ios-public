// libcurl: a system library on macOS, absent on iOS. Converted apps run with the network
// blocked (SHIMBlockNetwork), so this stand-in accepts handles and options and fails every
// transfer with CURLE_COULDNT_CONNECT, which games treat as "offline".
#import <Foundation/Foundation.h>
#include <stdarg.h>

enum { CURLE_OK = 0, CURLE_COULDNT_CONNECT = 7 };
#define EXPORT __attribute__((visibility("default")))

typedef struct { int unused; } ShimCurl;
typedef struct ShimSlist { char *data; struct ShimSlist *next; } ShimSlist;

EXPORT int curl_global_init(long flags) { return CURLE_OK; }
EXPORT int curl_global_init_mem(long flags, void *m, void *f, void *r, void *s, void *c) { return CURLE_OK; }
EXPORT void curl_global_cleanup(void) {}
EXPORT void *curl_easy_init(void) { return calloc(1, sizeof(ShimCurl)); }
EXPORT int curl_easy_setopt(void *h, int opt, ...) { return CURLE_OK; }
EXPORT int curl_easy_getinfo(void *h, int info, ...) {
    va_list ap; va_start(ap, info); void *out = va_arg(ap, void *); va_end(ap);
    if (out) memset(out, 0, sizeof(long));  // response code 0 / null pointers
    return CURLE_OK;
}
EXPORT int curl_easy_perform(void *h) {
    static int n; if (!n++) NSLog(@"SHIM curl: network disabled, transfers fail");
    return CURLE_COULDNT_CONNECT;
}
EXPORT void curl_easy_cleanup(void *h) { free(h); }
EXPORT const char *curl_easy_strerror(int code) { return code ? "Couldn't connect to server (network disabled)" : "No error"; }
EXPORT void *curl_multi_init(void) { return calloc(1, sizeof(ShimCurl)); }
EXPORT int curl_multi_add_handle(void *m, void *e) { return 0; }
EXPORT int curl_multi_remove_handle(void *m, void *e) { return 0; }
EXPORT int curl_multi_perform(void *m, int *running) { if (running) *running = 0; return 0; }
EXPORT void *curl_multi_info_read(void *m, int *left) { if (left) *left = 0; return NULL; }
EXPORT int curl_multi_cleanup(void *m) { free(m); return 0; }
EXPORT void *curl_slist_append(void *list, const char *s) {
    ShimSlist *n = calloc(1, sizeof *n); n->data = strdup(s ?: "");
    if (!list) return n;
    ShimSlist *l = list; while (l->next) l = l->next; l->next = n; return list;
}
EXPORT void curl_slist_free_all(void *list) {
    for (ShimSlist *l = list, *next; l; l = next) { next = l->next; free(l->data); free(l); }
}
