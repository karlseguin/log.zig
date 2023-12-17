const std = @import("std");

pub const Kv = @import("kv.zig").Kv;
pub const Pool = @import("pool.zig").Pool;
pub const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;

// We expect setup to possibly be called multiple times, but only initially.
// Specifically, calling setup with a minimum & hard-coding config right on
// startup, and then calling setup again after load config values. The caller
// is responsible for making sure setup is called in a thread-safe way (ideally)
// on startup, when there's only a single thread. The idea is to setup a basic
// logger early, so that any startup errors can be logged, possibly before the
// logger is "correctly" setup.
var init = false;
var global: Pool = undefined;

pub fn setup(allocator: Allocator, config: Config) !void {
	if (init) {
		global.deinit();
	}
	global = try Pool.init(allocator, config);
	init = true;
}

pub fn deinit() void {
	if (init) {
		global.deinit();
		init = false;
	}
}

pub const Level = enum(u3) {
	Debug,
	Info,
	Warn,
	Error,
	Fatal,
	None,

	pub fn parse(input: []const u8) ?Level {
		if (input.len < 4 or input.len > 5) return null;
		var buf: [5]u8 = undefined;

		const lower = std.ascii.lowerString(&buf, input);
		if (std.mem.eql(u8, lower, "debug")) return .Debug;
		if (std.mem.eql(u8, lower, "info")) return .Info;
		if (std.mem.eql(u8, lower, "warn")) return .Warn;
		if (std.mem.eql(u8, lower, "error")) return .Error;
		if (std.mem.eql(u8, lower, "fatal")) return .Fatal;
		if (std.mem.eql(u8, lower, "none")) return .None;
		return null;
	}
};

pub const Logger = struct {
	pool: *Pool,
	inner: union(enum) {
		kv: *Kv,
		noop: void,
	},

	const Self = @This();

	pub fn multiuse(self: Self) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.multiuse(),
		}
		return self;
	}

	pub fn ctx(self: Self, value: []const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.ctx(value),
		}
		return self;
	}

	pub fn src(self: Self, value: std.builtin.SourceLocation) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.src(value),
		}
		return self;
	}

	pub fn fmt(self: Self, key: []const u8, comptime format: []const u8, values: anytype) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.fmt(key, format, values),
		}
		return self;
	}

	pub fn string(self: Self, key: []const u8, value: ?[]const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.string(key, value),
		}
		return self;
	}

	pub fn stringZ(self: Self, key: []const u8, value: ?[*:0]const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.stringZ(key, value),
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

	pub fn stringSafeZ(self: Self, key: []const u8, value: ?[*:0]const u8) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.stringSafeZ(key, value),
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

	pub fn errK(self: Self, key: []const u8, value: anyerror) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.errK(key, value),
		}
		return self;
	}

	pub fn err(self: Self, value: anyerror) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.err(value),
		}
		return self;
	}

	pub fn level(self: Self, lvl: Level) Self {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.level(lvl),
		}
		return self;
	}

	pub fn tryLog(self: Self) !void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				defer self.maybeRelease(kv);
				if (self.pool.shouldLog(kv.lvl)) try kv.tryLog();
			}
		}
	}

	pub fn log(self: Self) void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				if (self.pool.shouldLog(kv.lvl)) kv.log();
				self.maybeRelease(kv);
			}
		}
	}

	pub fn logTo(self: Self, out: anytype) !void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				defer self.maybeRelease(kv);
				if (self.pool.shouldLog(kv.lvl)) try kv.logTo(out);
			}
		}
	}

	pub fn release(self: Self) void {
		switch (self.inner) {
			.noop => {},
			.kv => |kv| {
				self.pool.release(kv);
			},
		}
	}

	// to break the chain
	pub fn done(_: Self) void {
		return;
	}

	fn maybeRelease(self: Self, kv: *Kv) void {
		if (kv.multiuse_length == null) {
			self.pool.release(kv);
		} else {
			kv.reuse();
		}
	}
};

pub const noop = Logger{.pool = undefined, .inner = .{.noop = {}}};

pub fn level() Level {
	return @enumFromInt(global.level);
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

pub fn loggerL(lvl: Level) Logger {
	return global.loggerL(lvl);
}

const t = @import("t.zig");
test {
	std.testing.refAllDecls(@This());
}

test "level: parse" {
	try t.expectEqual(@as(?Level, null), Level.parse("Nope"));
	try t.expectEqual(@as(?Level, null), Level.parse(" info"));
	try t.expectEqual(@as(?Level, null), Level.parse("info "));
	try t.expectEqual(@as(?Level, null), Level.parse(""));
	try t.expectEqual(@as(?Level, null), Level.parse(" "));
	try t.expectEqual(@as(?Level, null), Level.parse("infoinfo"));

	try t.expectEqual(Level.Debug, Level.parse("debug").?);
	try t.expectEqual(Level.Debug, Level.parse("DEBUG").?);
	try t.expectEqual(Level.Debug, Level.parse("Debug").?);
	try t.expectEqual(Level.Debug, Level.parse("DeBuG").?);

	try t.expectEqual(Level.Info, Level.parse("info").?);
	try t.expectEqual(Level.Info, Level.parse("INFO").?);
	try t.expectEqual(Level.Info, Level.parse("Info").?);
	try t.expectEqual(Level.Info, Level.parse("InfO").?);

	try t.expectEqual(Level.Warn, Level.parse("warn").?);
	try t.expectEqual(Level.Warn, Level.parse("WARN").?);
	try t.expectEqual(Level.Warn, Level.parse("Warn").?);
	try t.expectEqual(Level.Warn, Level.parse("WArN").?);

	try t.expectEqual(Level.Error, Level.parse("error").?);
	try t.expectEqual(Level.Error, Level.parse("ERROR").?);
	try t.expectEqual(Level.Error, Level.parse("Error").?);
	try t.expectEqual(Level.Error, Level.parse("ErROr").?);

	try t.expectEqual(Level.Fatal, Level.parse("fatal").?);
	try t.expectEqual(Level.Fatal, Level.parse("FATAL").?);
	try t.expectEqual(Level.Fatal, Level.parse("Fatal").?);
	try t.expectEqual(Level.Fatal, Level.parse("faTAL").?);

	try t.expectEqual(Level.None, Level.parse("none").?);
	try t.expectEqual(Level.None, Level.parse("NONE").?);
	try t.expectEqual(Level.None, Level.parse("None").?);
	try t.expectEqual(Level.None, Level.parse("nONe").?);
}
