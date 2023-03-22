const logz = @import("logz.zig");

pub const Config = struct {
	pool_size: usize = 32,
	max_size: usize = 4096,
	level: logz.Level = .Info,
};
