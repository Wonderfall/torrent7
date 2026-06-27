#if defined(__APPLE__) && defined(__arm64e__)
// Apple Clang emits these SLS branch thunks for doctest's indirect calls, but
// this SwiftPM link path leaves the single-underscore Mach-O aliases undefined.
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl __llvm_slsblr_thunk_aaz_x8\n"
    ".private_extern __llvm_slsblr_thunk_aaz_x8\n"
    "__llvm_slsblr_thunk_aaz_x8:\n"
    "mov x16, x8\n"
    "braaz x16\n"
    "dsb sy\n"
    "isb\n"
    ".p2align 2\n"
    ".globl __llvm_slsblr_thunk_aaz_x9\n"
    ".private_extern __llvm_slsblr_thunk_aaz_x9\n"
    "__llvm_slsblr_thunk_aaz_x9:\n"
    "mov x16, x9\n"
    "braaz x16\n"
    "dsb sy\n"
    "isb\n"
);
#endif
