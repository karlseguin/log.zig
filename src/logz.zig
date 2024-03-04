const std = @import("std");

pub const Json = @import("json.zig").Json;
pub const Pool = @import("pool.zig").Pool;
pub const LogFmt = @import("logfmt.zig").LogFmt;
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
var global: *Pool = undefined;

pub fn setLevel(l: Level) void {
	if (@import("builtin").is_test == false) {
		@compileError("logz.setLevel can only be called during testing");
	}
	global.level = @intFromEnum(l);
}

pub fn writeMetrics(writer: anytype) !void {
	return @import("metrics.zig").write(writer);
}

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
		noop: void,
		json: *Json,
		logfmt: *LogFmt,
	},

	pub fn multiuse(self: Logger) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.multiuse(),
		}
		return self;
	}

	pub fn ctx(self: Logger, value: []const u8) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.ctx(value),
		}
		return self;
	}

	pub fn src(self: Logger, value: std.builtin.SourceLocation) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.src(value),
		}
		return self;
	}

	pub fn fmt(self: Logger, key: []const u8, comptime format: []const u8, values: anytype) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.fmt(key, format, values),
		}
		return self;
	}

	pub fn string(self: Logger, key: []const u8, value: ?[]const u8) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.string(key, value),
		}
		return self;
	}

	pub fn stringZ(self: Logger, key: []const u8, value: ?[*:0]const u8) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.stringZ(key, value),
		}
		return self;
	}

	pub fn stringSafe(self: Logger, key: []const u8, value: ?[]const u8) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.stringSafe(key, value),
		}
		return self;
	}

	pub fn stringSafeZ(self: Logger, key: []const u8, value: ?[*:0]const u8) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.stringSafeZ(key, value),
		}
		return self;
	}

	pub fn binary(self: Logger, key: []const u8, value: ?[]const u8) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.binary(key, value),
		}
		return self;
	}

	pub fn int(self: Logger, key: []const u8, value: anytype) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.int(key, value),
		}
		return self;
	}

	pub fn float(self: Logger, key: []const u8, value: anytype) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.float(key, value),
		}
		return self;
	}

	pub fn boolean(self: Logger, key: []const u8, value: anytype) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.boolean(key, value),
		}
		return self;
	}

	pub fn errK(self: Logger, key: []const u8, value: anyerror) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.errK(key, value),
		}
		return self;
	}

	pub fn err(self: Logger, value: anyerror) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.err(value),
		}
		return self;
	}

	pub fn level(self: Logger, lvl: Level) Logger {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.level(lvl),
		}
		return self;
	}

	pub fn tryLog(self: Logger) !void {
		switch (self.inner) {
			.noop => {},
			inline else => |l| {
				defer self.maybeRelease(l);
				if (self.pool.shouldLog(l.lvl)) try l.tryLog();
			}
		}
	}

	pub fn log(self: Logger) void {
		switch (self.inner) {
			.noop => {},
			inline else => |l| {
				if (self.pool.shouldLog(l.lvl)) l.log();
				self.maybeRelease(l);
			}
		}
	}

	pub fn logTo(self: Logger, out: anytype) !void {
		switch (self.inner) {
			.noop => {},
			inline else => |l| {
				defer self.maybeRelease(l);
				if (self.pool.shouldLog(l.lvl)) try l.logTo(out);
			}
		}
	}

	pub fn release(self: Logger) void {
		switch (self.inner) {
			.noop => {},
			else => self.pool.release(self),
		}
	}

	// to break the chain
	pub fn done(_: Logger) void {
		return;
	}

	fn maybeRelease(self: Logger, l: anytype) void {
		if (l.multiuse_length == null) {
			self.pool.release(self);
		} else {
			l.reuse();
		}
	}

	pub fn reset(self: Logger) void {
		switch (self.inner) {
			.noop => {},
			inline else => |l| l.reset(),
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
