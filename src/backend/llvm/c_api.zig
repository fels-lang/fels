/// Thin wrapper around the LLVM C API headers.
/// Import this module wherever you need raw LLVM types/functions.
pub const llvm = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/BitWriter.h");
    @cInclude("llvm-c/Support.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
    @cInclude("llvm-c/DebugInfo.h");
});
