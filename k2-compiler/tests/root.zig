const std = @import("std");
const lexer_tests = @import("compiler/lexer.zig");
const milestone_tests = @import("compiler/milestone.zig");
const features_tests = @import("compiler/features.zig");
const error_tests = @import("compiler/errors.zig");
const generics_tests     = @import("compiler/generics.zig");
const diagnostics_tests  = @import("compiler/diagnostics.zig");
const modules_tests      = @import("compiler/modules.zig");
const enums_tests        = @import("compiler/enums.zig");

comptime {
    _ = lexer_tests;
    _ = milestone_tests;
    _ = features_tests;
    _ = error_tests;
    _ = generics_tests;
    _ = diagnostics_tests;
    _ = modules_tests;
    _ = enums_tests;
}
