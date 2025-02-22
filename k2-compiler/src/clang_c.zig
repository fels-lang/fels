//! libclang C API binding (`clang-c/Index.h`). Only compiled when the compiler
//! is built with `-Dllvm-path=<path>`, which adds the SDK's include/lib paths
//! and links `libclang`. Used by `bindgen.zig` to parse arbitrary C headers.
pub const c = @cImport({
    @cInclude("clang-c/Index.h");
});
