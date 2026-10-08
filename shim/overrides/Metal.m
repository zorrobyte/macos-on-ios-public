// Metal on iOS: macOS's GPU enumeration with hot-plug observers. An iPad has one GPU and no
// eGPU/hot-plug, so report the system default device and a do-nothing observer.
#import <Metal/Metal.h>

__attribute__((visibility("default")))
NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id *observer, void (^handler)(id<MTLDevice>, NSString *)) {
    if (observer) *observer = [NSObject new];
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    return d ? @[d] : @[];
}

__attribute__((visibility("default"))) void MTLRemoveDeviceObserver(id observer) {}

__attribute__((visibility("default"))) NSArray<id<MTLDevice>> *MTLCopyAllDevices(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    return d ? @[d] : @[];
}
