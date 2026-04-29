const std = @import("std");
const t = @import("t.zig");

pub fn nowMilliseconds(io: std.Io) i64 {
    if (t.is_test) return t.timestamp();
    return std.Io.Clock.real.now(io).toMilliseconds();
}
