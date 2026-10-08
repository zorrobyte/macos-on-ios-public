// Runs on the Mac. For each "<library path> <symbol>" line on stdin, prints how the
// symbol looks in the real macOS library: "func", "data", "class <superclass>" or "missing".
// gen_shims uses this to emit the right kind of stub for iOS.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

static BOOL executable(const void *addr) {
    mach_vm_address_t a = (mach_vm_address_t)addr;
    mach_vm_size_t size;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj;
    if (mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj)) return NO;
    return (info.protection & VM_PROT_EXECUTE) != 0;
}

int main(void) {
    char line[4096];
    while (fgets(line, sizeof line, stdin)) {
        char *nl = strchr(line, '\n'); if (nl) *nl = 0;
        char *sp = strrchr(line, ' '); if (!sp) continue;
        *sp = 0;
        const char *lib = line, *sym = sp + 1;
        void *h = dlopen(lib, RTLD_LAZY | RTLD_GLOBAL);
        const char *cls = "_OBJC_CLASS_$_";
        if (!strncmp(sym, cls, strlen(cls))) {
            Class c = objc_getClass(sym + strlen(cls));
            Class s = c ? class_getSuperclass(c) : Nil;
            printf("%s %s\n", sym, c ? [[NSString stringWithFormat:@"class %s", s ? class_getName(s) : "NSObject"] UTF8String] : "missing");
            continue;
        }
        void *p = h ? dlsym(h, sym + 1) : NULL;  // dlsym takes the C name (no leading underscore)
        printf("%s %s\n", sym, !p ? "missing" : executable(p) ? "func" : "data");
    }
    return 0;
}
