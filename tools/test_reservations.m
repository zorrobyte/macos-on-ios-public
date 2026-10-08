// Test harness for libSystem_Reservations.m. Uses synthetic reserve helpers, not game code.
// Native arm64 regression harness; built by test_reservations.py.
#define mmap ShimTestMmap
#include "../shim/overrides/libSystem_Reservations.m"
#undef mmap
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

typedef struct { char *base, *end; } Span;
extern Span TestReservePage(void *, size_t, unsigned);
extern Span TestReserveAligned(void *, size_t, unsigned, unsigned, unsigned);
extern Span TestCallerRegisters(void *, size_t, unsigned);

// Two span-returning helpers with the same calling conventions as the engine.
#define RESERVE_BODY(ALIGNMENT, FAILURE_PADDING) \
    "stp x20, x19, [sp, #-32]!\n" \
    "stp x29, x30, [sp, #16]\n" \
    "add x29, sp, #16\n" \
    "mov w8, " ALIGNMENT "\n" \
    "add x9, x1, x8\n" \
    "sub x9, x9, #1\n" \
    "neg x8, x8\n" \
    "and x19, x9, x8\n" \
    "mov x0, #0\n" \
    "mov x1, x19\n" \
    "mov w2, #3\n" \
    "mov w3, #0x1002\n" \
    "mov w4, #-1\n" \
    "mov x5, #0\n" \
    "bl _ShimTestMmap\n" \
    "cmn x0, #1\n" \
    "b.eq 1f\n" \
    "add x1, x0, x19\n" \
    "ldp x29, x30, [sp, #16]\n" \
    "ldp x20, x19, [sp], #32\n" \
    "ret\n" \
    FAILURE_PADDING \
    "1: add x1, x0, x19\n" \
    "ldp x29, x30, [sp, #16]\n" \
    "ldp x20, x19, [sp], #32\n" \
    "ret\n"

__asm__(".text\n.p2align 2\n.globl _TestReservePage\n_TestReservePage:\n"
        RESERVE_BODY("w2", "")
        ".p2align 2\n.globl _TestReserveAligned\n_TestReserveAligned:\n"
        RESERVE_BODY("w4", "nop\nnop\nnop\n")
        ".p2align 2\n.globl _TestCallerRegisters\n_TestCallerRegisters:\n"
        "stp x20, x19, [sp, #-32]!\n"
        "stp x29, x30, [sp, #16]\n"
        "add x29, sp, #16\n"
        "mov x19, #0x123\n"
        "mov x20, #0x456\n"
        "bl _TestReservePage\n"
        "cmp x19, #0x123\n"
        "b.ne 1f\n"
        "cmp x20, #0x456\n"
        "b.ne 1f\n"
        "ldp x29, x30, [sp, #16]\n"
        "ldp x20, x19, [sp], #32\n"
        "ret\n"
        "1: brk #1\n");

static size_t observedLength;
static void *FailMmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    assert(!addr && prot == 3 && flags == 0x1002 && fd == -1 && !off);
    observedLength = len;
    errno = ENOMEM;
    return MAP_FAILED;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        BOOL enabled = !strcmp(argv[1], "enabled");
        assert(ShimBoundedReservations() == enabled);
        const size_t gib = 1ULL << 30;
        const size_t requested[] = {16 * gib, 64 * gib, 32 * gib, gib, gib};
        Span spans[5];
        for (size_t i = 0; i < 5; i++) {
            spans[i] = i == 1 ? TestReserveAligned(NULL, requested[i], 16384, 0, 16384)
                              : TestCallerRegisters(NULL, requested[i], 16384);
            size_t expected = enabled && requested[i] >= 8 * gib ? requested[i] / 4 : requested[i];
            assert(spans[i].base != MAP_FAILED);
            assert((uintptr_t)spans[i].end - (uintptr_t)spans[i].base == expected);
            assert(!((uintptr_t)spans[i].base & (getpagesize() - 1)));
            // First/last pages exercise the entire returned span, not just its prefix.
            assert(spans[i].base[0] == 0 && spans[i].end[-1] == 0);
            spans[i].base[0] = (char)(i + 1);
            spans[i].end[-1] = (char)(i + 11);
            assert(madvise(spans[i].base, getpagesize(), MADV_FREE_REUSABLE) == 0);
            assert(madvise(spans[i].base, getpagesize(), MADV_FREE_REUSE) == 0);
            spans[i].base[0] = (char)(i + 1);
            for (size_t j = 0; j < i; j++) {
                assert((uintptr_t)spans[i].end <= (uintptr_t)spans[j].base ||
                       (uintptr_t)spans[j].end <= (uintptr_t)spans[i].base);
            }
        }
        for (size_t i = 0; i < 5; i++) {
            assert(spans[i].base[0] == (char)(i + 1) && spans[i].end[-1] == (char)(i + 11));
            assert(munmap(spans[i].base, spans[i].end - spans[i].base) == 0);
        }

        // An ordinary mmap caller must receive its full requested mapping.
        char *plain = ShimTestMmap(NULL, 8 * gib, 3, 0x1002, -1, 0);
        assert(plain != MAP_FAILED);
        plain[8 * gib - 1] = 42;
        assert(plain[8 * gib - 1] == 42);
        assert(munmap(plain, 8 * gib) == 0);

        uint32_t instructions[21];
        memcpy(instructions, (const void *)TestReservePage, sizeof instructions);
        uintptr_t pc = (uintptr_t)&instructions[15];
        assert(ShimReservationCaller(pc));
        for (unsigned i = 0; i < 21; i++) {
            uint32_t saved = instructions[i];
            instructions[i] = 0;
            assert(!ShimReservationCaller(pc));
            instructions[i] = saved;
        }
        assert(!ShimReservationCaller(0));
        assert(!ShimReservationCaller(1));
        void *unreadable = ShimRealMmap(NULL, getpagesize(), PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        assert(unreadable != MAP_FAILED);
        assert(!ShimReservationCaller((uintptr_t)unreadable + 60));
        assert(munmap(unreadable, getpagesize()) == 0);

        ShimRealMmap = FailMmap;
        Span failed = TestCallerRegisters(NULL, 16 * gib, 16384);
        assert(failed.base == MAP_FAILED && errno == ENOMEM);
        assert(observedLength == (enabled ? 4 : 16) * gib);
        assert((uintptr_t)failed.end == 16 * gib - 1); // Failure leaves x19 unchanged.
        failed = TestCallerRegisters(NULL, 9 * gib, 16384);
        assert(failed.base == MAP_FAILED && observedLength == 9 * gib);
        failed = TestCallerRegisters(NULL, 12 * gib, 1U << 31);
        assert(failed.base == MAP_FAILED && observedLength == 12 * gib);
        puts("PASS: spans, disjoint arenas, boundary access, reuse/unmap, caller registers, guards, errno");
    }
    return 0;
}
