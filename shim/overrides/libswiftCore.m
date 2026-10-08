// Swift runtime pieces macOS has and iOS doesn't.
#include <stdbool.h>
#include <stdint.h>

// `if #available(macOS X, macCatalyst Y, *)` in zippered code calls this macOS-only
// entry point (Builtin.Int1 + six Builtin.Word versions -> Builtin.Int1). We run on a
// current iOS, so report "new enough" and let the game take its modern code paths.
__attribute__((visibility("default")))
bool shim_isOSVersionAtLeastOrVariant(bool useVariant, intptr_t major, intptr_t minor, intptr_t patch,
                                      intptr_t vMajor, intptr_t vMinor, intptr_t vPatch)
    __asm__("_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF");
bool shim_isOSVersionAtLeastOrVariant(bool useVariant, intptr_t major, intptr_t minor, intptr_t patch,
                                      intptr_t vMajor, intptr_t vMinor, intptr_t vPatch) {
    return true;
}
