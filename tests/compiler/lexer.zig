const std = @import("std");
const fels = @import("fels_compiler");

test "fels mod import test" {
    try std.testing.expect(@hasDecl(fels, "TokenKind"));
}
