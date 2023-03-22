const std = @import("std");
const t = @import("t.zig");
const logz = @import("logz.zig");

const Kv = @import("kv.zig").Kv;
const Config = @import("config.zig").Config;

const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

pub const Pool = struct {
	level: u3,
	mutex: Mutex,
	config: Config,
	loggers: []*Kv,
	available: usize,
	allocator: Allocator,

	const Self = @This();

	pub fn init(allocator: Allocator, config: Config) !Self {
		const size = config.pool_size;
		const loggers = try allocator.alloc(*Kv, size);

		for (0..size) |i| {
			var kv = try allocator.create(Kv);
			try kv.init(allocator, config);
			loggers[i] = kv;
		}

		return Self{
			.mutex = Mutex{},
			.config = config,
			.loggers = loggers,
			.available = size,
			.allocator = allocator,
			.level = @enumToInt(config.level),
		};
	}

	pub fn deinit(self: *Self) void {
		const allocator = self.allocator;
		for (self.loggers) |l| {
			l.deinit(allocator);
			allocator.destroy(l);
		}
		allocator.free(self.loggers);
	}

	pub fn acquire(self: *Self) ?*Kv {
		var m = self.mutex;
		m.lock();

		const loggers = self.loggers;
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			m.unlock();
			const allocator = self.allocator;

			var l = allocator.create(Kv) catch |e| {
				logDynamicAllocationFailure(e);
				return null;
			};

			l.init(allocator, self.config) catch |e| {
				allocator.destroy(l);
				logDynamicAllocationFailure(e);
				return null;
			};

			return l;
		}
		const index = available - 1;
		const l = loggers[index];
		self.available = index;
		m.unlock();
		return l;
	}

	pub fn release(self: *Self, l: *Kv) void {
		var m = self.mutex;
		m.lock();

		var loggers = self.loggers;
		const available = self.available;
		if (available == loggers.len) {
			m.unlock();
			const allocator = self.allocator;
			l.deinit(allocator);
			allocator.destroy(l);
			return;
		}
		l.reset();
		loggers[available] = l;
		self.available = available + 1;
		m.unlock();
	}

	pub fn debug(self: *Self) logz.Logger {
		return if (self.shouldLog(.Debug)) self.loggerWithLevel("DEBUG") else noop();
	}

	pub fn info(self: *Self) logz.Logger {
		return if (self.shouldLog(.Info)) self.loggerWithLevel("INFO") else noop();
	}

	pub fn warn(self: *Self) logz.Logger {
		return if (self.shouldLog(.Warn)) self.loggerWithLevel("WARN") else noop();
	}

	pub fn err(self: *Self) logz.Logger {
		return if (self.shouldLog(.Error)) self.loggerWithLevel("ERROR") else noop();
	}

	pub fn fatal(self: *Self) logz.Logger {
		return if (self.shouldLog(.Fatal)) self.loggerWithLevel("FATAL") else noop();
	}

	pub fn logger(self: *Self) logz.Logger {
		const kv = self.acquire() orelse return noop();
		return logz.Logger{.pool = self, .inner = .{.kv = kv}};
	}

	pub fn shouldLog(self: *Self, level: logz.Level) bool {
		return @enumToInt(level) >= self.level;
	}

	fn loggerWithLevel(self: *Self, level: []const u8) logz.Logger {
		var kv = self.acquire() orelse return noop();
		kv.start(level);
		return logz.Logger{.pool = self, .inner = .{.kv = kv}};
	}
};

fn noop() logz.Logger {
	return .{.pool = undefined, .inner = .{.noop = {}}};
}

fn logDynamicAllocationFailure(err: anyerror) void {
	const msg = "logz: logged pool is empty and we failed to dynamically allowcate a new loggger. Log will be dropped. Error was: {}";
	std.log.err(msg, .{err});
}

test "pool: shouldLog" {
	var min_config = Config{.pool_size = 1, .max_size = 1};

	{
		min_config.level = .Debug;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try t.expectEqual(true, p.shouldLog(.Debug));
		try t.expectEqual(true, p.shouldLog(.Info));
		try t.expectEqual(true, p.shouldLog(.Warn));
		try t.expectEqual(true, p.shouldLog(.Error));
		try t.expectEqual(true, p.shouldLog(.Fatal));
	}

	{
		min_config.level = .Info;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try t.expectEqual(false, p.shouldLog(.Debug));
		try t.expectEqual(true, p.shouldLog(.Info));
		try t.expectEqual(true, p.shouldLog(.Warn));
		try t.expectEqual(true, p.shouldLog(.Error));
		try t.expectEqual(true, p.shouldLog(.Fatal));
	}

	{
		min_config.level = .Warn;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try t.expectEqual(false, p.shouldLog(.Debug));
		try t.expectEqual(false, p.shouldLog(.Info));
		try t.expectEqual(true, p.shouldLog(.Warn));
		try t.expectEqual(true, p.shouldLog(.Error));
		try t.expectEqual(true, p.shouldLog(.Fatal));
	}

	{
		min_config.level = .Error;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try t.expectEqual(false, p.shouldLog(.Debug));
		try t.expectEqual(false, p.shouldLog(.Info));
		try t.expectEqual(false, p.shouldLog(.Warn));
		try t.expectEqual(true, p.shouldLog(.Error));
		try t.expectEqual(true, p.shouldLog(.Fatal));
	}

	{
		min_config.level = .Fatal;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try t.expectEqual(false, p.shouldLog(.Debug));
		try t.expectEqual(false, p.shouldLog(.Info));
		try t.expectEqual(false, p.shouldLog(.Warn));
		try t.expectEqual(false, p.shouldLog(.Error));
		try t.expectEqual(true, p.shouldLog(.Fatal));
	}

	{
		min_config.level = .None;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try t.expectEqual(false, p.shouldLog(.Debug));
		try t.expectEqual(false, p.shouldLog(.Info));
		try t.expectEqual(false, p.shouldLog(.Warn));
		try t.expectEqual(false, p.shouldLog(.Error));
		try t.expectEqual(false, p.shouldLog(.Fatal));
	}
}

test "pool: acquire and release" {
	// not 100% sure this is testing exactly what I want, but it's ....something ?
	const min_config = Config{.pool_size = 2, .max_size = 1};
	var p = try Pool.init(t.allocator, min_config);
	defer p.deinit();

	var l1a = p.acquire() orelse unreachable;
	var l2a = p.acquire() orelse unreachable;
	var l3a = p.acquire() orelse unreachable; // this should be dynamically generated

	try t.expectEqual(false, l1a == l2a);
	try t.expectEqual(false, l2a == l3a);

	p.release(l1a);

	var l1b = p.acquire() orelse unreachable;
	try t.expectEqual(true, l1a == l1b);

	p.release(l3a);
	p.release(l2a);
	p.release(l1b);
}

test "pool: log to kv" {
	var min_config = Config{.pool_size = 1, .max_size = 100};
	var out = std.ArrayList(u8).init(t.allocator);
	defer out.deinit();

	{
		min_config.level = .Debug;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try p.debug().int("a", 1).logTo(out.writer());
		try t.expectString("@l=DEBUG a=1\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("@l=INFO a=2\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("@l=WARN a=333\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@l=ERROR a=4444\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@l=FATAL aaa=zzzz\n", out.items[18..]);
	}

	{
		min_config.level = .Info;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		out.clearRetainingCapacity();
		try p.debug().int("a", 1).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("@l=INFO a=2\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("@l=WARN a=333\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@l=ERROR a=4444\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@l=FATAL aaa=zzzz\n", out.items[18..]);
	}

	{
		min_config.level = .Warn;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		out.clearRetainingCapacity();
		try p.debug().int("a", 1).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("@l=WARN a=333\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@l=ERROR a=4444\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@l=FATAL aaa=zzzz\n", out.items[18..]);
	}

	{
		min_config.level = .Error;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		out.clearRetainingCapacity();
		try p.debug().int("a", 1).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@l=ERROR a=4444\n", out.items[18..]);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@l=FATAL aaa=zzzz\n", out.items[18..]);
	}

	{
		min_config.level = .Fatal;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		out.clearRetainingCapacity();
		try p.debug().int("a", 1).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@l=FATAL aaa=zzzz\n", out.items[18..]);
	}

	{
		min_config.level = .None;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		out.clearRetainingCapacity();
		try p.debug().int("a", 1).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("", out.items);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("", out.items);
	}
}

test "pool: log to noop" {

}
