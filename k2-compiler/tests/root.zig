const std = @import("std");
const lexer_tests = @import("compiler/lexer.zig");
const milestone_tests = @import("compiler/milestone.zig");
const features_tests = @import("compiler/features.zig");

comptime {
    _ = lexer_tests;
    _ = milestone_tests;
    _ = features_tests;
}
