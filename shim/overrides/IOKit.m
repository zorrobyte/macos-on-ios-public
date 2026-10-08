// IOKit on iOS: Mac system-power notifications aren't available to apps, and callers
// (Unity) use the returned port without checking. Hand back a dummy port whose run loop
// source never fires.
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <dlfcn.h>

typedef struct IONotificationPort *IONotificationPortRef;
typedef void (*IOServiceInterestCallback)(void *refcon, mach_port_t service, uint32_t type, void *arg);

static struct { int unused; } gDummyPort;
static IONotificationPortRef const kDummyPort = (IONotificationPortRef)&gDummyPort;

static CFRunLoopSourceRef DummySource(void) {
    static CFRunLoopSourceRef source;
    if (!source) {
        CFRunLoopSourceContext ctx = {0};
        source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    }
    return source;
}

__attribute__((visibility("default")))
mach_port_t IORegisterForSystemPower(void *refcon, IONotificationPortRef *port, IOServiceInterestCallback cb, mach_port_t *notifier) {
    NSLog(@"SHIM IORegisterForSystemPower -> dummy port");
    if (port) *port = kDummyPort;
    if (notifier) *notifier = 1;
    return 1;  // nonzero = success
}

__attribute__((visibility("default"))) kern_return_t IODeregisterForSystemPower(mach_port_t *notifier) { return KERN_SUCCESS; }
__attribute__((visibility("default"))) kern_return_t IOAllowPowerChange(mach_port_t kernelPort, intptr_t id) { return KERN_SUCCESS; }
__attribute__((visibility("default"))) kern_return_t IOCancelPowerChange(mach_port_t kernelPort, intptr_t id) { return KERN_SUCCESS; }

// Real ports go to the real IOKit function.
__attribute__((visibility("default"))) CFRunLoopSourceRef IONotificationPortGetRunLoopSource(IONotificationPortRef port) {
    if (port == kDummyPort || !port) return DummySource();
    static CFRunLoopSourceRef (*real)(IONotificationPortRef);
    if (!real) real = dlsym(dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY), "IONotificationPortGetRunLoopSource");
    return real(port);
}

__attribute__((visibility("default"))) void IONotificationPortDestroy(IONotificationPortRef port) {
    if (port == kDummyPort || !port) return;
    static void (*real)(IONotificationPortRef);
    if (!real) real = dlsym(dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY), "IONotificationPortDestroy");
    real(port);
}
