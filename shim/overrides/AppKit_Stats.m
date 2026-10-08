// Once a second: "SHIM STATS fps=.. cpu=.. mem=.. avail=.. threads=.. thermal=.."
// (Info.plist SHIMStats). fps counts CAMetalLayer drawables handed out; cpu sums all threads
// (100 = one core); mem is the physical footprint iOS's memory limit is measured against;
// avail is what's left before that limit.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/proc.h>
#import <stdatomic.h>

static atomic_uint gDrawables;
static IMP gNextDrawable;

static id ShimNextDrawable(id self, SEL _cmd) {
    atomic_fetch_add(&gDrawables, 1);
    // Metal HUD follows a layer; games that swap or reconfigure layers lose it (Crimson Desert)
    static int hud = -1;
    if (hud < 0) hud = [NSBundle.mainBundle.infoDictionary[@"MetalHudEnabled"] boolValue];
    if (hud && !((CAMetalLayer *)self).developerHUDProperties)
        ((CAMetalLayer *)self).developerHUDProperties = @{@"mode": @"default"};
    return ((id (*)(id, SEL))gNextDrawable)(self, _cmd);
}

static double CPUPercent(int *threadCount) {
    thread_act_array_t threads;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return -1;
    double total = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &n) == KERN_SUCCESS && !(info.flags & TH_FLAGS_IDLE))
            total += info.cpu_usage * 100.0 / TH_USAGE_SCALE;
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    *threadCount = count;
    return total;
}

static _Atomic unsigned gLoops;

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) == KERN_SUCCESS ? info.phys_footprint / 1048576.0 : -1;
}

__attribute__((constructor)) static void ShimStatsInit(void) {
    NSNumber *on = NSBundle.mainBundle.infoDictionary[@"SHIMStats"];
    if (on && !on.boolValue) return;
    gNextDrawable = method_setImplementation(class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable)), (IMP)ShimNextDrawable);
    // main run-loop passes per second: ~0 means the main thread never returns to deliver input
    CFRunLoopAddObserver(CFRunLoopGetMain(), CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeSources, true, 0,
        ^(CFRunLoopObserverRef o, CFRunLoopActivity a) { atomic_fetch_add(&gLoops, 1); }), kCFRunLoopCommonModes);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        static const char *thermal[] = {"nominal", "fair", "serious", "critical"};
        int threads = 0;
        double cpu = CPUPercent(&threads);
        NSLog(@"SHIM STATS fps=%u cpu=%.0f mem=%.0f avail=%.0f threads=%d controllers=%lu loops=%u thermal=%s",
              atomic_exchange(&gDrawables, 0), cpu, FootprintMB(), os_proc_available_memory() / 1048576.0, threads, (unsigned long)GCController.controllers.count, atomic_exchange(&gLoops, 0),
              thermal[MIN(3, (int)NSProcessInfo.processInfo.thermalState)]);
    });
    dispatch_resume(timer);
    static dispatch_source_t keep;
    keep = timer;
}

// MARK: game controllers as iOS reports them (main thread), to compare with what the game sees
__attribute__((constructor)) static void ShimControllerLogInit(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSLog(@"SHIM GC controller connected: %@ (now %lu)", [n.object vendorName], (unsigned long)GCController.controllers.count);
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"SHIM GC controllers at startup (main thread): %lu", (unsigned long)GCController.controllers.count);
    });
}
