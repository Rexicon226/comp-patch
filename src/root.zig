const std = @import("std");
const builtin = @import("builtin");

// Just trap, Windows is fucky for 32-bit builds.
pub const panic = std.debug.no_panic;

pub const protocol = @import("protocol.zig");

pub const DllMain = switch (builtin.os.tag) {
    .windows => @import("windows.zig").DllMain,
    else => @compileError("you're holding it wrong"),
};
