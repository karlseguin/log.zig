const std = @import("std");
const logz = @import("logz.zig");

pub const Config = struct {
    pool_size: usize = 32,
    buffer_size: usize = 4096,
    level: logz.Level = .Info,
    prefix: ?[]const u8 = null,
    output: Output = .stdout,
    encoding: Encoding = .logfmt,
    pool_strategy: PoolStrategy = .create,
    large_buffer_count: u16 = 8,
    large_buffer_size: usize = 16384,
    large_buffer_strategy: LargeBufferStrategy = .create,

    pub const Output = union(enum) {
        stdout,
        stderr,
        file: []const u8,
    };

    pub const Encoding = enum {
        json,
        logfmt,
    };

    pub const PoolStrategy = enum {
        create,
        noop,
    };

    pub const LargeBufferStrategy = enum {
        create,
        drop,
    };
};
