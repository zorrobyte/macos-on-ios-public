// Security on iOS: log code-signing queries Mac games make about themselves and their
// libraries, then forward to the real iOS Security framework (results unchanged).
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef struct __SecCode *SecStaticCodeRef, *SecCodeRef;
typedef struct __SecRequirement *SecRequirementRef;

static void *Real(const char *name) {
    static void *h;
    if (!h) h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    return dlsym(h, name);
}

__attribute__((visibility("default")))
OSStatus SecStaticCodeCreateWithPath(CFURLRef path, uint32_t flags, SecStaticCodeRef *code) {
    OSStatus r = ((OSStatus (*)(CFURLRef, uint32_t, SecStaticCodeRef *))Real("SecStaticCodeCreateWithPath"))(path, flags, code);
    NSLog(@"SHIM Sec StaticCodeCreateWithPath %@ -> %d", ((__bridge NSURL *)path).path, (int)r);
    return r;
}

__attribute__((visibility("default")))
OSStatus SecStaticCodeCheckValidity(SecStaticCodeRef code, uint32_t flags, SecRequirementRef req) {
    OSStatus r = ((OSStatus (*)(SecStaticCodeRef, uint32_t, SecRequirementRef))Real("SecStaticCodeCheckValidity"))(code, flags, req);
    NSLog(@"SHIM Sec StaticCodeCheckValidity flags=%u -> %d", flags, (int)r);
    return r;
}

__attribute__((visibility("default")))
OSStatus SecCodeCopySelf(uint32_t flags, SecCodeRef *self) {
    OSStatus r = ((OSStatus (*)(uint32_t, SecCodeRef *))Real("SecCodeCopySelf"))(flags, self);
    NSLog(@"SHIM Sec CodeCopySelf -> %d", (int)r);
    return r;
}

__attribute__((visibility("default")))
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, uint32_t flags, CFDictionaryRef *info) {
    OSStatus r = ((OSStatus (*)(SecStaticCodeRef, uint32_t, CFDictionaryRef *))Real("SecCodeCopySigningInformation"))(code, flags, info);
    NSDictionary *d = info ? (__bridge NSDictionary *)*info : nil;
    NSLog(@"SHIM Sec CodeCopySigningInformation flags=%u -> %d team=%@ id=%@", flags, (int)r, d[@"teamid"], d[@"identifier"]);
    return r;
}
