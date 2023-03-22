const std = @import("std");

pub const Kv = @import("kv.zig").Kv;
pub const Pool = @import("pool.zig").Pool;
pub const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;

var global: Pool = undefined;

pub fn setup(allocator: Allocator, config: Config) !void {
	global = try Pool.init(allocator, config);
}

pub const Level = enum(u3) {
	Debug,
	Info,
	Warn,
	Error,
	Fatal,
	None,
};

pub const Logger = struct {
	pool: *Pool,
	inner: union(enum) {
		kv: *Kv,
		noop: void,
	},

	const Self = @This();

	pub fn string(self: Self, key: []const u8, value: ?[]const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.string(key, value),
		}
		return self;
	}

	pub fn stringSafe(self: Self, key: []const u8, value: ?[]const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.stringSafe(key, value),
		}
		return self;
	}

	pub fn binary(self: Self, key: []const u8, value: ?[]const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.binary(key, value),
		}
		return self;
	}

	pub fn int(self: Self, key: []const u8, value: anytype) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.int(key, value),
		}
		return self;
	}

	pub fn float(self: Self, key: []const u8, value: anytype) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.float(key, value),
		}
		return self;
	}

	pub fn boolean(self: Self, key: []const u8, value: anytype) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.boolean(key, value),
		}
		return self;
	}

	pub fn err(self: Self, key: []const u8, value: anyerror) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.err(key, value),
		}
		return self;
	}

	pub fn log(self: Self) !void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				try kv.log();
				self.pool.release(kv);
			}
		}
	}

	pub fn logTo(self: Self, out: anytype) !void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				try kv.logTo(out);
				self.pool.release(kv);
			}
		}
	}

	pub fn release(self: Self) void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				kv.reset();
				self.pool.release(kv);
			},
		}
	}
};

pub fn level() Level {
	return @intToEnum(Level, global.level);
}

pub fn shouldLog(l: Level) bool {
	return global.shouldLog(l);
}

pub fn debug() Logger {
	return global.debug();
}

pub fn info() Logger {
	return global.info();
}

pub fn warn() Logger {
	return global.warn();
}

pub fn err() Logger {
	return global.err();
}

pub fn fatal() Logger {
	return global.fatal();
}

pub fn logger() Logger {
	return global.logger();
}

test {
	std.testing.refAllDecls(@This());
}
