const logz = @import("logz.zig");

pub const Config = struct {
	pool_size: usize = 32,
	buffer_size: usize = 4096,
	level: logz.Level = .Info,
	prefix: ?[]const u8 = null,
	output: Output = .stdout,
	encoding: Encoding = .logfmt,
	pool_empty: PoolEmpty = .create,
	large_buffer_count: u16 = 8,
	large_buffer_size: usize = 16384,

	pub const Output = enum {
		stdout,
		stderr,
	};

	pub const Encoding = enum {
		json,
		logfmt,
	};

	pub const PoolEmpty = enum {
		create,
		noop,
	};
};
