// Symbols that flat-namespace Mac libraries (e.g. Mono's libmonobdwgc) look up in "any
// loaded image" but iOS lacks. The AppKit shim is always loaded, so they live here.
#import <stdarg.h>
#import <syslog.h>

// macOS-only JIT page toggle. iOS apps can't have JIT pages; Mono runs interpreter-only.
__attribute__((visibility("default"))) void pthread_jit_write_protect_np(int enabled) {}

// macOS spelling of syslog for the UNIX03/Darwin-extension variant.
__attribute__((visibility("default"))) void shim_syslog_darwin(int pri, const char *fmt, ...) __asm__("_syslog$DARWIN_EXTSN");
void shim_syslog_darwin(int pri, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsyslog(pri, fmt, ap);
    va_end(ap);
}
