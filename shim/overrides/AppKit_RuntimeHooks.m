// Process-level fixes for Mac binaries on iOS, installed before main() runs.
// - Bundle path: Info.plist SHIMMacRoot = "Mac" means the Mac app tree lives in
//   <app>/Mac/Contents; -[NSBundle bundlePath]/executablePath/resourcePath on the main bundle
//   report <app>/Mac, <app>/Mac/Contents/MacOS/<exe> and <app>/Mac/Contents/Resources as on macOS.
// - Mono: iOS forbids JIT, so the moment libmonobdwgc loads we switch it to
//   interpreter-only (MONO_AOT_MODE_INTERP_ONLY). Override with SHIM_MONO_AOT_MODE.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

enum { MONO_AOT_MODE_INTERP_ONLY = 8 };

static void ImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !strstr(info.dli_fname, "libmonobdwgc")) return;
    void *h = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY);
    void (*setMode)(int) = h ? dlsym(h, "mono_jit_set_aot_mode") : NULL;
    const char *env = getenv("SHIM_MONO_AOT_MODE");
    int mode = env ? atoi(env) : MONO_AOT_MODE_INTERP_ONLY;
    NSLog(@"SHIM mono loaded (%s), aot mode -> %d (%s)", info.dli_fname, mode, setMode ? "set" : "NOT FOUND");
    if (setMode) setMode(mode);
}

static NSString *gMacRoot;
static IMP gBundlePath, gExecutablePath, gResourcePath;

static NSString *ShimResourcePath(NSBundle *self, SEL _cmd) {
    return self == NSBundle.mainBundle && gMacRoot ? [gMacRoot stringByAppendingPathComponent:@"Contents/Resources"]
                                                   : ((NSString *(*)(id, SEL))gResourcePath)(self, _cmd);
}

static NSString *ShimBundlePath(NSBundle *self, SEL _cmd) {
    return self == NSBundle.mainBundle && gMacRoot ? gMacRoot : ((NSString *(*)(id, SEL))gBundlePath)(self, _cmd);
}

static NSString *ShimExecutablePath(NSBundle *self, SEL _cmd) {
    NSString *real = ((NSString *(*)(id, SEL))gExecutablePath)(self, _cmd);
    if (self != NSBundle.mainBundle || !gMacRoot) return real;
    return [gMacRoot stringByAppendingFormat:@"/Contents/MacOS/%@", real.lastPathComponent];
}

// URL variants report the same Mac paths (No Man's Sky: resourceURL.path + "/GAMEDATA").
static IMP gBundleURL, gExecutableURL, gResourceURL;
static NSURL *ShimBundleURL(NSBundle *self, SEL _cmd) {
    return self == NSBundle.mainBundle && gMacRoot ? [NSURL fileURLWithPath:ShimBundlePath(self, @selector(bundlePath)) isDirectory:YES]
                                                   : ((NSURL *(*)(id, SEL))gBundleURL)(self, _cmd);
}
static NSURL *ShimResourceURL(NSBundle *self, SEL _cmd) {
    return self == NSBundle.mainBundle && gMacRoot ? [NSURL fileURLWithPath:ShimResourcePath(self, @selector(resourcePath)) isDirectory:YES]
                                                   : ((NSURL *(*)(id, SEL))gResourceURL)(self, _cmd);
}
static NSURL *ShimExecutableURL(NSBundle *self, SEL _cmd) {
    return self == NSBundle.mainBundle && gMacRoot ? [NSURL fileURLWithPath:ShimExecutablePath(self, @selector(executablePath))]
                                                   : ((NSURL *(*)(id, SEL))gExecutableURL)(self, _cmd);
}

// Main-bundle resource lookups fall back to the Mac tree's Contents/Resources.
static IMP gPathForResource, gURLForResource;
static NSString *ShimMacResource(NSString *name, NSString *ext) {
    NSString *file = ext.length ? [name stringByAppendingPathExtension:ext] : name;
    NSString *p = [gMacRoot stringByAppendingFormat:@"/Contents/Resources/%@", file];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}
static NSString *ShimPathForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    NSString *r = ((NSString *(*)(id, SEL, id, id))gPathForResource)(self, _cmd, name, ext);
    if (r || self != NSBundle.mainBundle || !name) return r;
    return ShimMacResource(name, ext);
}
static NSURL *ShimURLForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    NSURL *r = ((NSURL *(*)(id, SEL, id, id))gURLForResource)(self, _cmd, name, ext);
    if (r || self != NSBundle.mainBundle || !name) return r;
    NSString *p = ShimMacResource(name, ext);
    return p ? [NSURL fileURLWithPath:p] : nil;
}

__attribute__((constructor)) static void ShimRuntimeInit(void) {
    _dyld_register_func_for_add_image(ImageAdded);
    NSBundle *main = NSBundle.mainBundle;
    NSString *root = main.infoDictionary[@"SHIMMacRoot"];
    if (root) {
        Method bp = class_getInstanceMethod(NSBundle.class, @selector(bundlePath));
        Method ep = class_getInstanceMethod(NSBundle.class, @selector(executablePath));
        gMacRoot = [main.bundlePath stringByAppendingPathComponent:root];
        gBundlePath = method_setImplementation(bp, (IMP)ShimBundlePath);
        gExecutablePath = method_setImplementation(ep, (IMP)ShimExecutablePath);
        gResourcePath = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(resourcePath)), (IMP)ShimResourcePath);
        gBundleURL = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(bundleURL)), (IMP)ShimBundleURL);
        gResourceURL = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(resourceURL)), (IMP)ShimResourceURL);
        gExecutableURL = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(executableURL)), (IMP)ShimExecutableURL);
        gPathForResource = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(pathForResource:ofType:)), (IMP)ShimPathForResource);
        gURLForResource = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(URLForResource:withExtension:)), (IMP)ShimURLForResource);
        NSLog(@"SHIM bundle path -> %@", gMacRoot);
        // Diagnostic: games often dlopen their own libraries and hide the loader error.
        NSString *fw = [gMacRoot stringByAppendingPathComponent:@"Contents/Frameworks"];
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:fw error:nil]) {
            if (![f.pathExtension isEqualToString:@"dylib"]) continue;
            void *h = dlopen([fw stringByAppendingPathComponent:f].fileSystemRepresentation, RTLD_LAZY);
            NSLog(@"SHIM preload %@: %s", f, h ? "ok" : dlerror());
        }
    }
}

// MARK: Network block (Info.plist SHIMBlockNetwork) — test builds must not phone home
// (crash reporters like Sentry, telemetry). Fails every URL-loading request.

@interface ShimBlockProtocol : NSURLProtocol
@end
@implementation ShimBlockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { NSLog(@"SHIM blocked %@", r.URL.host); return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)stopLoading {}
@end

static IMP gProtocolClasses;
static NSArray *ShimProtocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
    NSArray *real = ((NSArray *(*)(id, SEL))gProtocolClasses)(self, _cmd);
    return [@[ShimBlockProtocol.class] arrayByAddingObjectsFromArray:real ?: @[]];
}

__attribute__((constructor)) static void ShimNetworkInit(void) {
    if (![NSBundle.mainBundle.infoDictionary[@"SHIMBlockNetwork"] boolValue]) return;
    [NSURLProtocol registerClass:ShimBlockProtocol.class];
    Method m = class_getInstanceMethod(NSURLSessionConfiguration.class, @selector(protocolClasses));
    gProtocolClasses = method_setImplementation(m, (IMP)ShimProtocolClasses);
    NSLog(@"SHIM network blocked");
}

// MARK: Mac-only methods on real iOS objects (e.g. -[MTLDevice setShouldMaximizeConcurrentCompilation:])
// Unknown messages to these classes are forwarded to a sink that logs them once and returns 0.
// respondsToSelector: is unaffected, so a game's own availability checks stay truthful.

@interface ShimSink : NSProxy
@end
@implementation ShimSink
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSUInteger args = [[NSStringFromSelector(sel) componentsSeparatedByString:@":"] count] - 1;
    return [NSMethodSignature signatureWithObjCTypes:[@"Q@:" stringByPaddingToLength:3 + args withString:@"Q" startingAtIndex:0].UTF8String];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    static NSMutableSet *seen;
    @synchronized (ShimSink.class) {
        if (!seen) seen = [NSMutableSet new];
        NSString *name = NSStringFromSelector(inv.selector);
        if (![seen containsObject:name]) { [seen addObject:name]; NSLog(@"SHIM absorbed Mac-only -%@", name); }
    }
    uint64_t zero = 0;
    [inv setReturnValue:&zero];
}
@end

static id ShimForwardToSink(id self, SEL _cmd, SEL sel) {
    static ShimSink *sink;
    if (!sink) sink = [ShimSink alloc];
    return sink;
}

static void ShimAbsorbMissing(Class c) {
    if (c) class_addMethod(c, @selector(forwardingTargetForSelector:), (IMP)ShimForwardToSink, "@@::");
}

// MARK: Metal default library lives in the Mac tree (Mac/Contents/Resources/default.metallib)

static id<MTLLibrary> ShimMacDefaultLibrary(id<MTLDevice> device) {
    NSString *path = [gMacRoot stringByAppendingPathComponent:@"Contents/Resources/default.metallib"];
    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
    NSLog(@"SHIM Metal default library %@ -> %@ %@", path.lastPathComponent, lib ? @"loaded" : @"FAILED", err ?: @"");
    return lib;
}
static id ShimNewDefaultLibrary(id self, SEL _cmd) { return ShimMacDefaultLibrary(self); }
static id ShimNewDefaultLibraryWithBundle(id self, SEL _cmd, NSBundle *bundle, NSError **error) { return ShimMacDefaultLibrary(self); }

static IMP gNewFunction;
static id ShimNewFunctionWithName(id self, SEL _cmd, NSString *name) {
    id f = ((id (*)(id, SEL, id))gNewFunction)(self, _cmd, name);
    if (!f) NSLog(@"SHIM Metal function not found: %@ in %@", name, [self label] ?: self);
    return f;
}

// Log Metal shader-library and function creation failures (Mac-built shaders on iOS).
static IMP gLibData, gLibURL, gFnConst, gFnDesc;
static id ShimLibData(id self, SEL _cmd, dispatch_data_t data, NSError **error) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, id, NSError **))gLibData)(self, _cmd, data, &e);
    // Older Mac metallibs (format v4, e.g. No Man's Sky) are refused on iOS while newer ones load.
    // Header byte 5 bit 0x80 marks macOS; retry once with it cleared.
    NSData *bytes = (NSData *)data;
    if (!lib && bytes.length > 8 && !memcmp(bytes.bytes, "MTLB", 4) && (((uint8_t *)bytes.bytes)[5] & 0x80)) {
        NSMutableData *ios = [bytes mutableCopy];
        ((uint8_t *)ios.mutableBytes)[5] &= 0x7f;
        dispatch_data_t d = dispatch_data_create(ios.bytes, ios.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *e2 = nil;
        lib = ((id (*)(id, SEL, id, NSError **))gLibData)(self, _cmd, d, &e2);
        static int retried;
        if (!retried++) NSLog(@"SHIM Metal Mac metallib retried as iOS -> %@ %@", lib ? @"ok" : @"FAILED", e2 ?: @"");
        if (lib) e = nil;
    }
    static int ok;
    static int failed;
    if (!lib) {
        NSLog(@"SHIM Metal newLibraryWithData (%zu bytes) FAILED: %@", dispatch_data_get_size(data), e);
        if (failed++ < 3) {  // keep a few for inspection: Documents/shimdump/lib<N>.bin
            NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/shimdump"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [(NSData *)data writeToFile:[dir stringByAppendingFormat:@"/lib%d.bin", failed] atomically:NO];
        }
    }
    else if (!ok++) NSLog(@"SHIM Metal newLibraryWithData ok (first), functions: %@", [[lib functionNames] subarrayWithRange:NSMakeRange(0, MIN(3, [lib functionNames].count))]);
    if (error) *error = e;
    return lib;
}
static id ShimLibURL(id self, SEL _cmd, NSURL *url, NSError **error) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, id, NSError **))gLibURL)(self, _cmd, url, &e);
    NSLog(@"SHIM Metal newLibraryWithURL %@ -> %@ %@", url.lastPathComponent, lib ? @"ok" : @"FAILED", e ?: @"");
    if (error) *error = e;
    return lib;
}
static id ShimFnConst(id self, SEL _cmd, NSString *name, id values, NSError **error) {
    NSError *e = nil;
    id f = ((id (*)(id, SEL, id, id, NSError **))gFnConst)(self, _cmd, name, values, &e);
    if (!f) NSLog(@"SHIM Metal newFunctionWithName:%@ constantValues FAILED: %@", name, e);
    if (error) *error = e;
    return f;
}
static id ShimFnDesc(id self, SEL _cmd, id desc, NSError **error) {
    NSError *e = nil;
    id f = ((id (*)(id, SEL, id, NSError **))gFnDesc)(self, _cmd, desc, &e);
    if (!f) NSLog(@"SHIM Metal newFunctionWithDescriptor:%@ FAILED: %@", [desc name], e);
    if (error) *error = e;
    return f;
}

// Mac games pick shader sets by Mac GPU family; on iPadOS an Apple-silicon GPU reports only
// Apple/Common/Metal families. Same hardware, so also claim MTLGPUFamilyMac2.
static IMP gSupportsFamily;
static BOOL ShimSupportsFamily(id self, SEL _cmd, MTLGPUFamily family) {
    if (family == MTLGPUFamilyMac2) return YES;
    return ((BOOL (*)(id, SEL, MTLGPUFamily))gSupportsFamily)(self, _cmd, family);
}

static IMP gLibFile, gLibSource, gC4Lib;
static id ShimLibFile(id self, SEL _cmd, NSString *path, NSError **error) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, id, NSError **))gLibFile)(self, _cmd, path, &e);
    NSLog(@"SHIM Metal newLibraryWithFile %@ -> %@ %@", path, lib ? @"ok" : @"FAILED", e ?: @"");
    if (error) *error = e;
    return lib;
}
static id ShimLibSource(id self, SEL _cmd, NSString *src, id opts, NSError **error) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, id, id, NSError **))gLibSource)(self, _cmd, src, opts, &e);
    NSLog(@"SHIM Metal newLibraryWithSource (%lu chars) -> %@ %@", (unsigned long)src.length, lib ? @"ok" : @"FAILED", e ?: @"");
    if (error) *error = e;
    return lib;
}
static id ShimC4Lib(id self, SEL _cmd, id desc, NSError **error) {
    NSError *e = nil;
    id lib = ((id (*)(id, SEL, id, NSError **))gC4Lib)(self, _cmd, desc, &e);
    NSLog(@"SHIM Metal MTL4Compiler newLibraryWithDescriptor %@ -> %@ %@", [desc name], lib ? @"ok" : @"FAILED", e ?: @"");
    if (error) *error = e;
    return lib;
}

// MTLStorageModeManaged (macOS-only, value 1) is invalid on iOS; on Apple silicon it behaves
// like Shared, so convert it wherever resources are described.
static const NSUInteger kManagedOption = 1 << MTLResourceStorageModeShift;  // MTLResourceStorageModeManaged
static NSUInteger ShimFixOptions(NSUInteger options, const char *where) {
    if ((options & MTLResourceStorageModeMask) != kManagedOption) return options;
    static int n;
    if (!n++) NSLog(@"SHIM Metal managed storage -> shared (first at %s)", where);
    return (options & ~MTLResourceStorageModeMask) | MTLResourceStorageModeShared;
}
static IMP gBufLen, gBufBytes, gBufNoCopy, gTexSetMode, gTexSetOpts, gHeapSetMode, gHeapSetOpts;
static id ShimBufLen(id self, SEL _cmd, NSUInteger len, NSUInteger opts) {
    return ((id (*)(id, SEL, NSUInteger, NSUInteger))gBufLen)(self, _cmd, len, ShimFixOptions(opts, "newBufferWithLength"));
}
static id ShimBufBytes(id self, SEL _cmd, const void *p, NSUInteger len, NSUInteger opts) {
    return ((id (*)(id, SEL, const void *, NSUInteger, NSUInteger))gBufBytes)(self, _cmd, p, len, ShimFixOptions(opts, "newBufferWithBytes"));
}
static id ShimBufNoCopy(id self, SEL _cmd, void *p, NSUInteger len, NSUInteger opts, id dealloc) {
    return ((id (*)(id, SEL, void *, NSUInteger, NSUInteger, id))gBufNoCopy)(self, _cmd, p, len, ShimFixOptions(opts, "newBufferWithBytesNoCopy"), dealloc);
}
static void ShimTexSetMode(id self, SEL _cmd, NSUInteger mode) {
    if (mode == 1) { ShimFixOptions(kManagedOption, "texture storageMode"); mode = MTLStorageModeShared; }
    ((void (*)(id, SEL, NSUInteger))gTexSetMode)(self, _cmd, mode);
}
static void ShimTexSetOpts(id self, SEL _cmd, NSUInteger opts) {
    ((void (*)(id, SEL, NSUInteger))gTexSetOpts)(self, _cmd, ShimFixOptions(opts, "texture resourceOptions"));
}
static void ShimHeapSetMode(id self, SEL _cmd, NSUInteger mode) {
    if (mode == 1) { ShimFixOptions(kManagedOption, "heap storageMode"); mode = MTLStorageModeShared; }
    ((void (*)(id, SEL, NSUInteger))gHeapSetMode)(self, _cmd, mode);
}
static void ShimHeapSetOpts(id self, SEL _cmd, NSUInteger opts) {
    ((void (*)(id, SEL, NSUInteger))gHeapSetOpts)(self, _cmd, ShimFixOptions(opts, "heap resourceOptions"));
}
static IMP Swap(Class c, SEL s, IMP imp) {
    Method m = class_getInstanceMethod(c, s);
    return m ? method_setImplementation(m, imp) : NULL;
}

__attribute__((constructor)) static void ShimAbsorbInit(void) {
    if ([NSBundle.mainBundle.infoDictionary[@"SHIMNoEarlyMetal"] boolValue]) { NSLog(@"SHIM early Metal setup skipped"); return; }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Class dc = object_getClass(device);
    ShimAbsorbMissing(dc);
    ShimAbsorbMissing(CAMetalLayer.class);
    if (gMacRoot) {
        method_setImplementation(class_getInstanceMethod(dc, @selector(newDefaultLibrary)), (IMP)ShimNewDefaultLibrary);
        method_setImplementation(class_getInstanceMethod(dc, @selector(newDefaultLibraryWithBundle:error:)), (IMP)ShimNewDefaultLibraryWithBundle);
    }
    // library class: compile a trivial library to find it
    id<MTLLibrary> probe = [device newLibraryWithSource:@"kernel void k(){}" options:nil error:nil];
    Method nf = class_getInstanceMethod(object_getClass(probe), @selector(newFunctionWithName:));
    if (nf) gNewFunction = method_setImplementation(nf, (IMP)ShimNewFunctionWithName);
    gSupportsFamily = method_setImplementation(class_getInstanceMethod(dc, @selector(supportsFamily:)), (IMP)ShimSupportsFamily);
    gLibFile = method_setImplementation(class_getInstanceMethod(dc, @selector(newLibraryWithFile:error:)), (IMP)ShimLibFile);
    gLibSource = method_setImplementation(class_getInstanceMethod(dc, @selector(newLibraryWithSource:options:error:)), (IMP)ShimLibSource);
    if (@available(iOS 26.0, *)) {
        id compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
        Method cm = compiler ? class_getInstanceMethod(object_getClass(compiler), @selector(newLibraryWithDescriptor:error:)) : NULL;
        if (cm) gC4Lib = method_setImplementation(cm, (IMP)ShimC4Lib);
    }
    gBufLen = Swap(dc, @selector(newBufferWithLength:options:), (IMP)ShimBufLen);
    gBufBytes = Swap(dc, @selector(newBufferWithBytes:length:options:), (IMP)ShimBufBytes);
    gBufNoCopy = Swap(dc, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), (IMP)ShimBufNoCopy);
    gTexSetMode = Swap(MTLTextureDescriptor.class, @selector(setStorageMode:), (IMP)ShimTexSetMode);
    gTexSetOpts = Swap(MTLTextureDescriptor.class, @selector(setResourceOptions:), (IMP)ShimTexSetOpts);
    gHeapSetMode = Swap(MTLHeapDescriptor.class, @selector(setStorageMode:), (IMP)ShimHeapSetMode);
    gHeapSetOpts = Swap(MTLHeapDescriptor.class, @selector(setResourceOptions:), (IMP)ShimHeapSetOpts);
    Class lc = object_getClass(probe);
    gLibData = method_setImplementation(class_getInstanceMethod(dc, @selector(newLibraryWithData:error:)), (IMP)ShimLibData);
    gLibURL = method_setImplementation(class_getInstanceMethod(dc, @selector(newLibraryWithURL:error:)), (IMP)ShimLibURL);
    gFnConst = method_setImplementation(class_getInstanceMethod(lc, @selector(newFunctionWithName:constantValues:error:)), (IMP)ShimFnConst);
    gFnDesc = method_setImplementation(class_getInstanceMethod(lc, @selector(newFunctionWithDescriptor:error:)), (IMP)ShimFnDesc);
}

// MARK: reported RAM for NSProcessInfo (sysctl side is in libSystem.m)
static unsigned long long gReportedMemory;
static unsigned long long ShimPhysicalMemory(id self, SEL _cmd) { return gReportedMemory; }

__attribute__((constructor)) static void ShimMemoryInit(void) {
    NSNumber *gb = NSBundle.mainBundle.infoDictionary[@"SHIMReportedMemoryGB"];
    if (!gb) return;
    gReportedMemory = (unsigned long long)(gb.doubleValue * 1073741824.0);
    method_setImplementation(class_getInstanceMethod(NSProcessInfo.class, @selector(physicalMemory)), (IMP)ShimPhysicalMemory);
    NSLog(@"SHIM reporting %.0f GB of RAM", gb.doubleValue);
}

// MARK: run-loop modes. On macOS, AppKit's modes (NSEventTrackingRunLoopMode, NSModalPanelRunLoopMode)
// are common modes, so input sources keep firing while a game pumps in them. On iOS they are
// unknown custom modes and UIKit/GameController input never arrives. Any non-default mode a game
// runs gets added to the common modes (logged once per mode).
static IMP gRunModeIMP;
static BOOL ShimRunMode(NSRunLoop *self, SEL _cmd, NSRunLoopMode mode, NSDate *limit) {
    static NSMutableSet *seen;
    if (mode && ![mode isEqualToString:NSDefaultRunLoopMode] && ![mode isEqualToString:NSRunLoopCommonModes]) {
        @synchronized (NSRunLoop.class) {
            if (!seen) seen = [NSMutableSet new];
            if (![seen containsObject:mode]) {
                [seen addObject:mode];
                CFRunLoopAddCommonMode(self.getCFRunLoop, (__bridge CFStringRef)mode);
                NSLog(@"SHIM run loop mode %@ added to common modes", mode);
            }
        }
    }
    return ((BOOL (*)(id, SEL, id, id))gRunModeIMP)(self, _cmd, mode, limit);
}

__attribute__((constructor)) static void ShimRunLoopModesInit(void) {
    for (NSString *m in @[@"NSEventTrackingRunLoopMode", @"NSModalPanelRunLoopMode"])
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), (__bridge CFStringRef)m);
    gRunModeIMP = method_setImplementation(class_getInstanceMethod(NSRunLoop.class, @selector(runMode:beforeDate:)), (IMP)ShimRunMode);
}

// MARK: method tracing (Info.plist SHIMTrace: ["Class.selector", ...]): logs the first 20 calls of
// each listed method, then calls the original. For void methods with up to 4 pointer-sized args.
static NSMutableDictionary<NSString *, NSValue *> *gTraced;
static void ShimTraceIMP(id self, SEL _cmd, void *a, void *b, void *c, void *d) {
    IMP orig = NULL; NSString *key = nil;
    for (Class k = object_getClass(self); k && !orig; k = class_getSuperclass(k)) {
        key = [NSString stringWithFormat:@"%s %s", class_getName(k), sel_getName(_cmd)];
        orig = gTraced[key].pointerValue;
    }
    static NSMutableDictionary *counts;
    @synchronized (NSNull.null) {
        if (!counts) counts = [NSMutableDictionary new];
        int n = [counts[key] intValue] + 1; counts[key] = @(n);
        if (n <= 20) NSLog(@"SHIM trace -[%@] #%d arg=%p", key, n, a);
    }
    if (orig) ((void (*)(id, SEL, void *, void *, void *, void *))orig)(self, _cmd, a, b, c, d);
}

static void ShimInstallTraces(void) {
    gTraced = [NSMutableDictionary new];
    for (NSString *entry in NSBundle.mainBundle.infoDictionary[@"SHIMTrace"]) {
        NSArray *p = [entry componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
        Class c = NSClassFromString(p.firstObject);
        Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(p.lastObject)) : NULL;
        if (!m) { NSLog(@"SHIM trace: %@ not found", entry); continue; }
        NSString *key = [NSString stringWithFormat:@"%@ %@", p.firstObject, p.lastObject];
        gTraced[key] = [NSValue valueWithPointer:method_setImplementation(m, (IMP)ShimTraceIMP)];
        NSLog(@"SHIM trace on %@", entry);
    }
}

__attribute__((constructor)) static void ShimTraceInit(void) {
    if (!NSBundle.mainBundle.infoDictionary[@"SHIMTrace"]) return;
    // game classes come from the main executable, which is initialized after this library
    dispatch_async(dispatch_get_main_queue(), ^{ ShimInstallTraces(); });
}

// MARK: frame pacing log: what the game asks the display for (logged when the value changes)
static IMP gSetRange, gPresentMin, gDrawablePresentMin;
static void ShimLogPacing(NSString *what, double a, double b, double c) {
    static NSMutableDictionary *last;
    @synchronized (NSNull.null) {
        if (!last) last = [NSMutableDictionary new];
        NSString *v = [NSString stringWithFormat:@"%.4f %.4f %.4f", a, b, c];
        if ([last[what] isEqualToString:v]) return;
        last[what] = v;
    }
    NSLog(@"SHIM pacing %@: %.4f %.4f %.4f", what, a, b, c);
}
static void ShimSetRange(id self, SEL _cmd, CAFrameRateRange r) {
    ShimLogPacing(@"displayLink preferredFrameRateRange min/max/preferred", r.minimum, r.maximum, r.preferred);
    ((void (*)(id, SEL, CAFrameRateRange))gSetRange)(self, _cmd, r);
}
static void ShimPresentMin(id self, SEL _cmd, id drawable, CFTimeInterval d) {
    ShimLogPacing(@"commandBuffer presentDrawable afterMinimumDuration (ms)", d * 1000, 0, 0);
    ((void (*)(id, SEL, id, CFTimeInterval))gPresentMin)(self, _cmd, drawable, d);
}
static void ShimDrawablePresentMin(id self, SEL _cmd, CFTimeInterval d) {
    ShimLogPacing(@"drawable presentAfterMinimumDuration (ms)", d * 1000, 0, 0);
    ((void (*)(id, SEL, CFTimeInterval))gDrawablePresentMin)(self, _cmd, d);
}

__attribute__((constructor)) static void ShimPacingLogInit(void) {
    if (@available(iOS 17.0, *)) {
        Method m = class_getInstanceMethod(CAMetalDisplayLink.class, @selector(setPreferredFrameRateRange:));
        if (m) gSetRange = method_setImplementation(m, (IMP)ShimSetRange);
    }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    Method pm = cb ? class_getInstanceMethod(object_getClass(cb), @selector(presentDrawable:afterMinimumDuration:)) : NULL;
    if (pm) gPresentMin = method_setImplementation(pm, (IMP)ShimPresentMin);
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = dev; layer.drawableSize = CGSizeMake(16, 16);
    id<CAMetalDrawable> d = [layer nextDrawable];
    Method dm = d ? class_getInstanceMethod(object_getClass(d), @selector(presentAfterMinimumDuration:)) : NULL;
    if (dm) gDrawablePresentMin = method_setImplementation(dm, (IMP)ShimDrawablePresentMin);
}

// MARK: GameController diagnostics: does the game install input handlers, and do they fire?
#import <GameController/GameController.h>
static IMP gSetButtonHandler, gSetDpadHandler, gSetPadHandler;
static _Atomic int gGCHandlersSet, gGCFired;
static void ShimSetButtonHandler(id self, SEL _cmd, GCControllerButtonValueChangedHandler h) {
    if (atomic_fetch_add(&gGCHandlersSet, 1) < 3) NSLog(@"SHIM GC game set button handler on %@", [self localizedName] ?: NSStringFromClass([self class]));
    GCControllerButtonValueChangedHandler w = h ? ^(GCControllerButtonInput *b, float v, BOOL p) {
        if (atomic_fetch_add(&gGCFired, 1) < 5) NSLog(@"SHIM GC button handler fired %@ %.2f", b.localizedName, v);
        h(b, v, p);
    } : nil;
    ((void (*)(id, SEL, id))gSetButtonHandler)(self, _cmd, w);
}
static void ShimSetDpadHandler(id self, SEL _cmd, GCControllerDirectionPadValueChangedHandler h) {
    if (atomic_fetch_add(&gGCHandlersSet, 1) < 3) NSLog(@"SHIM GC game set dpad handler");
    GCControllerDirectionPadValueChangedHandler w = h ? ^(GCControllerDirectionPad *d, float x, float y) {
        if (atomic_fetch_add(&gGCFired, 1) < 5) NSLog(@"SHIM GC dpad handler fired %.2f %.2f", x, y);
        h(d, x, y);
    } : nil;
    ((void (*)(id, SEL, id))gSetDpadHandler)(self, _cmd, w);
}
static void ShimSetPadHandler(id self, SEL _cmd, GCExtendedGamepadValueChangedHandler h) {
    NSLog(@"SHIM GC game set extendedGamepad handler");
    GCExtendedGamepadValueChangedHandler w = h ? ^(GCExtendedGamepad *g, GCControllerElement *e) {
        if (atomic_fetch_add(&gGCFired, 1) < 5) NSLog(@"SHIM GC gamepad handler fired");
        h(g, e);
    } : nil;
    ((void (*)(id, SEL, id))gSetPadHandler)(self, _cmd, w);
}
__attribute__((constructor)) static void HookGCHandlers(void) {
    gSetButtonHandler = method_setImplementation(class_getInstanceMethod(GCControllerButtonInput.class, @selector(setValueChangedHandler:)), (IMP)ShimSetButtonHandler);
    gSetDpadHandler = method_setImplementation(class_getInstanceMethod(GCControllerDirectionPad.class, @selector(setValueChangedHandler:)), (IMP)ShimSetDpadHandler);
    gSetPadHandler = method_setImplementation(class_getInstanceMethod(GCExtendedGamepad.class, @selector(setValueChangedHandler:)), (IMP)ShimSetPadHandler);
}
