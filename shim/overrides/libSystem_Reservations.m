// Compatibility adapter for engines that reserve more address space than iOS gives an app.
// Opt-in (SHIMBoundedReservations). Never writes game code: it reads the calling function's
// instructions to recognize a reserve helper, then grants a smaller anonymous mapping and
// reports the granted bounds to that helper. Everything else passes through to mmap unchanged.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach/mach.h>
#import <stdatomic.h>
#import <sys/mman.h>

static void *(*ShimRealMmap)(void *, size_t, int, int, int, off_t);

// Match a reserve helper returning {base, end}, including its restoration of x19.
static BOOL ShimReservationCaller(uintptr_t pc) {
    uint32_t code[21];
    vm_size_t copied = 0;
    if (pc < 60 || (pc & 3) || vm_read_overwrite(mach_task_self(), pc - 60,
            sizeof code, (vm_address_t)code, &copied) != KERN_SUCCESS || copied != sizeof code) return NO;
    const uint32_t before[] = {
        0xa9be4ff4, 0xa9017bfd, 0x910043fd, // save x19/x20, fp/lr
        0, 0x8b080029, 0xd1000529, 0xcb0803e8, 0x8a080133, // round length into x19
        0xd2800000, 0xaa1303e1, 0x52800062, 0x52820043, 0x12800004, 0xd2800005
    };
    for (size_t i = 0; i < sizeof before / sizeof *before; i++) {
        if (i == 3) {
            if (code[i] != 0x2a0203e8 && code[i] != 0x2a0403e8) return NO; // alignment in w2 or w4
        } else if (code[i] != before[i]) return NO;
    }
    return (code[14] & 0xfc000000) == 0x94000000 && // bl mmap
        code[15] == 0xb100041f &&
        (code[16] == 0x540000a0 || code[16] == 0x54000100) &&
        code[17] == 0x8b130001 && // end = base + x19
        code[18] == 0xa9417bfd && code[19] == 0xa8c24ff4 && code[20] == 0xd65f03c0;
}

static BOOL ShimBoundedReservations(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        enabled = [info[@"SHIMBoundedReservations"] boolValue] || [info[@"SHIMShrinkReservations"] boolValue];
    });
    return enabled;
}

static void ShimDumpVM(void) {
    static atomic_flag dumped = ATOMIC_FLAG_INIT;
    if (atomic_flag_test_and_set(&dumped)) return;
    vm_address_t address = 0, previousEnd = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                          (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (kr != KERN_SUCCESS) break;
        if (address - previousEnd >= (1ULL << 30))
            NSLog(@"SHIM vm gap %#lx-%#lx %.1f GB", previousEnd, address, (address - previousEnd) / 1073741824.0);
        if (size >= (256ULL << 20))
            NSLog(@"SHIM vm region %#lx-%#lx %.1f GB prot=%d/%d", address, address + size,
                  size / 1073741824.0, info.protection, info.max_protection);
        if (!size || address > UINT64_MAX - size) break;
        previousEnd = address + size;
        address = previousEnd;
    }
    NSLog(@"SHIM vm end %#lx", previousEnd);
}

typedef struct { void *base; size_t helperLength; } ShimMmapResult;

__attribute__((used, noinline))
static ShimMmapResult ShimMmapReservation(void *addr, size_t len, int prot, int flags, int fd,
                                         off_t off, uintptr_t caller, size_t helperLength) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ShimRealMmap = dlsym(dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY), "mmap");
    });
    size_t actual = len;
    if (!addr && fd == -1 && !off && prot == (PROT_READ | PROT_WRITE) &&
        flags == (MAP_PRIVATE | MAP_ANON) && len >= (8ULL << 30) && ShimBoundedReservations()) {
        // Quartering an 8 GiB multiple preserves every 32-bit power-of-two alignment.
        if (helperLength == len && !(len & ((8ULL << 30) - 1)) && ShimReservationCaller(caller)) {
            actual = len / 4;
        } else {
            NSLog(@"SHIM reserve unchanged len=%zu caller=%p (unsupported helper or size)", len, (void *)caller);
        }
    }
    void *base = ShimRealMmap(addr, actual, prot, flags, fd, off);
    if (base == MAP_FAILED) {
        int error = errno;
        NSLog(@"SHIM mmap FAILED requested=%zu mapped=%zu prot=0x%x flags=0x%x fd=%d errno=%d",
              len, actual, prot, flags, fd, error);
        ShimDumpVM();
        errno = error;
        return (ShimMmapResult){base, 0};
    }
    if (actual != len) {
        NSLog(@"SHIM reserve bounded %.0f -> %.0f GiB base=%p end=%p caller=%p",
              len / 1073741824.0, actual / 1073741824.0, base, (char *)base + actual, (void *)caller);
        return (ShimMmapResult){base, actual};
    }
    return (ShimMmapResult){base, 0};
}

#if defined(__arm64__)
// Only the matched helper permits changing its live x19 length.
// Its checked epilogue restores the enclosing caller's original x19.
__attribute__((visibility("default"), naked))
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"
        "mov x6, x30\n"
        "mov x7, x19\n"
        "bl _ShimMmapReservation\n"
        "cbz x1, 1f\n"
        "mov x19, x1\n"
        "1: ldp x29, x30, [sp], #16\n"
        "ret\n");
}
#else
__attribute__((visibility("default")))
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    return ShimMmapReservation(addr, len, prot, flags, fd, off, 0, 0).base;
}
#endif
