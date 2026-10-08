// libSystem on iOS: path redirects, case-insensitive paths, crash-site logging.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <dirent.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdio.h>
#import <sys/stat.h>
#import <signal.h>
#import <objc/runtime.h>
#import <sys/ucontext.h>
#import <unistd.h>

// MARK: Path redirects (Info.plist SHIMPathRedirects: {"/Resources/Packages": "Documents/packages"})
// Big game data lives in the app's Documents (pushed once, survives reinstalls) instead of
// the bundle. Any path containing a key (case-insensitive) is rewritten from that point to
// <home>/<value>. Covers the libc file calls Mac games use.

static NSDictionary<NSString *, NSString *> *Redirects(void) {
    static NSDictionary *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = NSBundle.mainBundle.infoDictionary[@"SHIMPathRedirects"] ?: @{}; });
    return r;
}

static const char *FixCase(const char *path, char *buf, size_t size);

// Returns path itself, or a rewritten copy in buf (redirects, then case-insensitive matching).
static const char *RedirectOnly(const char *path, char *buf, size_t size);
static const char *Redirect(const char *path, char *buf, size_t size) {
    if (!path) return path;
    char tmp[PATH_MAX];
    const char *p = RedirectOnly(path, tmp, sizeof tmp);
    const char *f = FixCase(p, buf, size);
    if (f == p && p == tmp) { strlcpy(buf, tmp, size); return buf; }
    return f;
}
// Info.plist SHIMAppParentRedirect = "Documents/<game>": games that keep data next to their .app
// (Cyberpunk: archive/, engine/, r6/) see the iOS install folder there, which is read-only and
// changes per install. Paths in the app's parent folder (other than the app) go to <home>/<value>.
static const char *AppParentRedirect(const char *path, char *buf, size_t size) {
    static char parent[PATH_MAX], privParent[PATH_MAX], app[NAME_MAX + 1];
    static size_t parentLen, privLen;
    static NSString *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = NSBundle.mainBundle.infoDictionary[@"SHIMAppParentRedirect"];
        char exe[PATH_MAX]; uint32_t n = sizeof exe;
        if (!target || _NSGetExecutablePath(exe, &n)) return;
        NSString *appPath = @(exe).stringByDeletingLastPathComponent;            // .../<UUID>/X.app
        strlcpy(app, appPath.lastPathComponent.fileSystemRepresentation, sizeof app);
        strlcpy(parent, appPath.stringByDeletingLastPathComponent.fileSystemRepresentation, sizeof parent);
        if (!strncmp(parent, "/private/", 9)) strlcpy(privParent, parent + 8, sizeof privParent);
        else snprintf(privParent, sizeof privParent, "/private%s", parent);
        parentLen = strlen(parent); privLen = strlen(privParent);
    });
    if (!target || !parentLen || !path) return path;
    const char *rest = NULL;
    if (!strncmp(path, parent, parentLen) && path[parentLen] == '/') rest = path + parentLen + 1;
    else if (!strncmp(path, privParent, privLen) && path[privLen] == '/') rest = path + privLen + 1;
    if (!rest || (!strncmp(rest, app, strlen(app)) && (rest[strlen(app)] == '/' || !rest[strlen(app)]))) return path;
    snprintf(buf, size, "%s/%s/%s", NSHomeDirectory().fileSystemRepresentation, target.UTF8String, rest);
    return buf;
}

static const char *RedirectOnly(const char *path, char *buf, size_t size) {
    const char *a = AppParentRedirect(path, buf, size);
    if (a != path) return a;
    if (!path || !Redirects().count) return path;
    for (NSString *key in Redirects()) {
        const char *hit = strcasestr(path, key.UTF8String);
        if (!hit) continue;
        snprintf(buf, size, "%s/%s%s", NSHomeDirectory().fileSystemRepresentation, Redirects()[key].UTF8String, hit + key.length);
        return buf;
    }
    return path;
}

static void *RealLibc(const char *name);

// Mac file systems ignore case and Mac games rely on it (Crimson Desert lowercases its whole
// save path). For paths inside the app container, match each component case-insensitively
// against the disk, like macOS. Only runs when the exact path doesn't exist.
static const char *FixCase(const char *path, char *buf, size_t size) {
    static char home[PATH_MAX], privHome[PATH_MAX];
    static size_t homeLen, privLen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strlcpy(home, NSHomeDirectory().fileSystemRepresentation, sizeof home);  // /private/var/mobile/... or /var/...
        if (!strncmp(home, "/private/", 9)) strlcpy(privHome, home + 8, sizeof privHome);       // /var/...
        else snprintf(privHome, sizeof privHome, "/private%s", home);
        homeLen = strlen(home); privLen = strlen(privHome);
    });
    size_t prefix = 0;
    if (!strncasecmp(path, home, homeLen)) prefix = homeLen;
    else if (!strncasecmp(path, privHome, privLen)) prefix = privLen;
    else return path;
    static int (*realAccess)(const char *, int);
    if (!realAccess) realAccess = RealLibc("access");
    if (realAccess(path, F_OK) == 0) return path;
    static DIR *(*realOpendir)(const char *);
    if (!realOpendir) realOpendir = RealLibc("opendir");
    char out[PATH_MAX];
    strlcpy(out, home, sizeof out);
    const char *rest = path + prefix;
    while (*rest == '/') rest++;
    while (*rest) {
        const char *slash = strchr(rest, '/');
        size_t len = slash ? (size_t)(slash - rest) : strlen(rest);
        char comp[NAME_MAX + 1];
        snprintf(comp, sizeof comp, "%.*s", (int)len, rest);
        char probe[PATH_MAX];
        snprintf(probe, sizeof probe, "%s/%s", out, comp);
        if (realAccess(probe, F_OK) != 0) {
            DIR *d = realOpendir(out);
            struct dirent *e;
            while (d && (e = readdir(d))) if (!strcasecmp(e->d_name, comp)) { strlcpy(comp, e->d_name, sizeof comp); break; }
            if (d) closedir(d);
        }
        strlcat(out, "/", sizeof out);
        strlcat(out, comp, sizeof out);
        rest += len;
        while (*rest == '/') rest++;
    }
    strlcpy(buf, out, size);
    return buf;
}

static void *RealLibc(const char *name) {
    static void *h;
    if (!h) h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    return dlsym(h, name);
}

#define REAL(ret, name, ...) static ret (*real)(__VA_ARGS__); if (!real) real = RealLibc(name)

// First 40 distinct paths the app looks for and doesn't find (where does it expect its data?).
static void LogMissing(const char *call, const char *path, int r) {
    if (r != -1 || errno != ENOENT || !path) return;
    static NSMutableSet *seen; static int n;
    @synchronized (NSNull.null) {
        if (n >= 40) return;
        if (!seen) seen = [NSMutableSet new];
        NSString *k = @(path);
        if ([seen containsObject:k]) return;
        [seen addObject:k]; n++;
    }
    int e = errno;
    NSLog(@"SHIM missing file (%s): %s", call, path);
    errno = e;
}
#define EXPORT __attribute__((visibility("default")))

EXPORT int open(const char *path, int flags, ...) {
    REAL(int, "open", const char *, int, ...);
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    char buf[PATH_MAX]; int r = real(Redirect(path, buf, sizeof buf), flags, mode);
    LogMissing("open", path, r); return r;
}
EXPORT FILE *fopen(const char *path, const char *m) { REAL(FILE *, "fopen", const char *, const char *); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf), m); }
EXPORT int stat(const char *path, struct stat *st) {
    REAL(int, "stat", const char *, struct stat *); char buf[PATH_MAX];
    int r = real(Redirect(path, buf, sizeof buf), st); LogMissing("stat", path, r); return r;
}
EXPORT int access(const char *path, int m) {
    REAL(int, "access", const char *, int); char buf[PATH_MAX];
    int r = real(Redirect(path, buf, sizeof buf), m); LogMissing("access", path, r); return r;
}
EXPORT DIR *opendir(const char *path) { REAL(DIR *, "opendir", const char *); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf)); }
EXPORT int mkdir(const char *path, mode_t m) { REAL(int, "mkdir", const char *, mode_t); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf), m); }
EXPORT int rmdir(const char *path) { REAL(int, "rmdir", const char *); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf)); }
EXPORT int unlink(const char *path) { REAL(int, "unlink", const char *); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf)); }
EXPORT int remove(const char *path) { REAL(int, "remove", const char *); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf)); }
EXPORT int chdir(const char *path) {
    REAL(int, "chdir", const char *);
    char buf[PATH_MAX];
    const char *p = Redirect(path, buf, sizeof buf);
    int r = real(p);
    NSLog(@"SHIM chdir \"%s\" (as %s) -> %d", path, p, r);
    return r;
}
// Mac games derive their folders from the executable path; report the Mac layout like
// -[NSBundle executablePath] does (the real binary sits at the bundle root, see convert_app.py).
EXPORT int _NSGetExecutablePath(char *out, uint32_t *size) {
    REAL(int, "_NSGetExecutablePath", char *, uint32_t *);
    char exe[PATH_MAX]; uint32_t n = sizeof exe;
    if (real(exe, &n) != 0) return real(out, size);
    NSString *root = NSBundle.mainBundle.infoDictionary[@"SHIMMacRoot"];
    NSString *path = @(exe);
    if (root) path = [NSString stringWithFormat:@"%@/%@/Contents/MacOS/%@",
                      path.stringByDeletingLastPathComponent, root, path.lastPathComponent];
    const char *c = path.fileSystemRepresentation;
    if (strlen(c) + 1 > *size) { *size = (uint32_t)strlen(c) + 1; return -1; }
    strlcpy(out, c, *size);
    return 0;
}
// Foundation's chdir doesn't come through the export above (No Man's Sky: changeCurrentDirectoryPath:
// <bundle>/Contents/Resources/GAMEDATA, then opens gpu.cfg relative to it).
static BOOL ShimChangeDir(id self, SEL _cmd, NSString *path) { return chdir(path.fileSystemRepresentation) == 0; }
// Same for existence checks (No Man's Sky tests Contents/Resources/GAMEDATA before changing into it).
static BOOL ShimExistsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
    struct stat st;
    if (!path || stat(path.fileSystemRepresentation, &st) != 0) return NO;  // our stat redirects
    if (isDir) *isDir = S_ISDIR(st.st_mode);
    return YES;
}
static BOOL ShimExists(id self, SEL _cmd, NSString *path) { return ShimExistsDir(self, _cmd, path, NULL); }
__attribute__((constructor)) static void HookChangeDir(void) {
    class_replaceMethod(NSFileManager.class, @selector(changeCurrentDirectoryPath:), (IMP)ShimChangeDir, "c@:@");
    class_replaceMethod(NSFileManager.class, @selector(fileExistsAtPath:), (IMP)ShimExists, "c@:@");
    class_replaceMethod(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:), (IMP)ShimExistsDir, "c@:@^c");
}
EXPORT int rename(const char *a, const char *b) {
    REAL(int, "rename", const char *, const char *);
    char b1[PATH_MAX], b2[PATH_MAX]; return real(Redirect(a, b1, sizeof b1), Redirect(b, b2, sizeof b2));
}
EXPORT char *shim_realpath(const char *path, char *out) __asm__("_realpath$DARWIN_EXTSN");
char *shim_realpath(const char *path, char *out) {
    REAL(char *, "realpath$DARWIN_EXTSN", const char *, char *); char buf[PATH_MAX]; return real(Redirect(path, buf, sizeof buf), out);
}

// MARK: reported RAM (Info.plist SHIMReportedMemoryGB). Some engines size their address-space
// reservations from RAM; a constrained device may need to report less.
// NSProcessInfo.physicalMemory is handled in RuntimeHooks.
#import <sys/sysctl.h>
uint64_t ShimReportedMemory(void) {
    static uint64_t v = UINT64_MAX;
    if (v == UINT64_MAX) {
        NSNumber *gb = NSBundle.mainBundle.infoDictionary[@"SHIMReportedMemoryGB"];
        v = gb ? (uint64_t)(gb.doubleValue * 1073741824.0) : 0;
    }
    return v;
}
EXPORT int sysctlbyname(const char *name, void *old, size_t *oldlen, void *newp, size_t newlen) {
    REAL(int, "sysctlbyname", const char *, void *, size_t *, void *, size_t);
    int r = real(name, old, oldlen, newp, newlen);
    if (r == 0 && name && ShimReportedMemory() && (!strcmp(name, "hw.memsize") || !strcmp(name, "hw.physmem"))
        && old && oldlen && *oldlen >= sizeof(uint64_t)) {
        *(uint64_t *)old = ShimReportedMemory();
        NSLog(@"SHIM sysctl %s -> %.0f GB", name, ShimReportedMemory() / 1073741824.0);
    }
    return r;
}
EXPORT int sysctl(int *mib, u_int n, void *old, size_t *oldlen, void *newp, size_t newlen) {
    REAL(int, "sysctl", int *, u_int, void *, size_t *, void *, size_t);
    int r = real(mib, n, old, oldlen, newp, newlen);
    if (r == 0 && n >= 2 && mib[0] == CTL_HW && mib[1] == HW_MEMSIZE && ShimReportedMemory() && old && oldlen && *oldlen >= 8) {
        *(uint64_t *)old = ShimReportedMemory();
        NSLog(@"SHIM sysctl hw.memsize (mib) -> %.0f GB", ShimReportedMemory() / 1073741824.0);
    }
    return r;
}

// MARK: Crash handlers
// Games install their own SIGSEGV/SIGBUS handlers, which swallow crashes (no iOS crash report;
// No Man's Sky prints "Caught SIGSEGV" and spins). Log where the fault is, then run theirs.
static struct sigaction gGameAction[NSIG];

static void ShimLogAddr(const char *what, uintptr_t a) {
    Dl_info d = {0};
    char line[400];
    if (dladdr((void *)a, &d) && d.dli_fname) {
        const char *base = strrchr(d.dli_fname, '/');
        snprintf(line, sizeof line, "SHIM FAULT %s 0x%lx = %s+0x%lx (%s)\n", what, (unsigned long)a,
                 base ? base + 1 : d.dli_fname, (unsigned long)(a - (uintptr_t)d.dli_fbase), d.dli_sname ?: "?");
    } else {
        snprintf(line, sizeof line, "SHIM FAULT %s 0x%lx\n", what, (unsigned long)a);
    }
    write(2, line, strlen(line));
}

static void ShimFault(int sig, siginfo_t *si, void *ctx) {
    static int logged;
    if (logged++ < 3) {
        ucontext_t *uc = ctx;
        char line[120];
        snprintf(line, sizeof line, "SHIM FAULT signal %d address 0x%lx\n", sig, (unsigned long)si->si_addr);
        write(2, line, strlen(line));
        ShimLogAddr("pc", (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
        ShimLogAddr("lr", (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
    }
    struct sigaction *g = &gGameAction[sig];
    if (g->sa_flags & SA_SIGINFO) g->sa_sigaction(sig, si, ctx);
    else if (g->sa_handler != SIG_DFL && g->sa_handler != SIG_IGN) g->sa_handler(sig);
    else signal(sig, SIG_DFL);  // returns and re-faults with the default action
}

EXPORT int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    REAL(int, "sigaction", int, const struct sigaction *, struct sigaction *);
    BOOL fault = sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGABRT;
    if (!fault || !act || act->sa_handler == SIG_DFL || act->sa_handler == SIG_IGN) return real(sig, act, old);
    struct sigaction prev = gGameAction[sig], mine = *act;
    mine.sa_sigaction = ShimFault;
    mine.sa_flags |= SA_SIGINFO;
    int r = real(sig, &mine, old);
    if (r == 0) {
        if (old && old->sa_sigaction == ShimFault) *old = prev;
        gGameAction[sig] = *act;
    }
    return r;
}

EXPORT void (*signal(int sig, void (*h)(int)))(int) {
    struct sigaction act = {0}, old = {0};
    act.sa_handler = h;
    sigemptyset(&act.sa_mask);
    return sigaction(sig, &act, &old) == 0 ? old.sa_handler : SIG_ERR;
}
