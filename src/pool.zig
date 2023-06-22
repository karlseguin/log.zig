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
			kv.* = try Kv.init(allocator, config);
			loggers[i] = kv;
		}

		return Self{
			.mutex = Mutex{},
			.config = config,
			.loggers = loggers,
			.available = size,
			.allocator = allocator,
			.level = @intFromEnum(config.level),
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
		self.mutex.lock();

		const loggers = self.loggers;
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();
			const allocator = self.allocator;

			var kv = allocator.create(Kv) catch |e| {
				logDynamicAllocationFailure(e);
				return null;
			};

			kv.* = Kv.init(allocator, self.config) catch |e| {
				allocator.destroy(kv);
				logDynamicAllocationFailure(e);
				return null;
			};

			return kv;
		}
		const index = available - 1;
		const kv = loggers[index];
		self.available = index;
		self.mutex.unlock();
		return kv;
	}

	pub fn release(self: *Self, l: *Kv) void {
		l.reset();
		self.mutex.lock();

		var loggers = self.loggers;
		const available = self.available;
		if (available == loggers.len) {
			self.mutex.unlock();
			const allocator = self.allocator;
			l.deinit(allocator);
			allocator.destroy(l);
			return;
		}
		loggers[available] = l;
		self.available = available + 1;
		self.mutex.unlock();
	}

	pub fn debug(self: *Self) logz.Logger {
		return if (self.shouldLog(.Debug)) self.loggerWithLevel(.Debug) else logz.noop;
	}

	pub fn info(self: *Self) logz.Logger {
		return if (self.shouldLog(.Info)) self.loggerWithLevel(.Info) else logz.noop;
	}

	pub fn warn(self: *Self) logz.Logger {
		return if (self.shouldLog(.Warn)) self.loggerWithLevel(.Warn) else logz.noop;
	}

	pub fn err(self: *Self) logz.Logger {
		return if (self.shouldLog(.Error)) self.loggerWithLevel(.Error) else logz.noop;
	}

	pub fn fatal(self: *Self) logz.Logger {
		return if (self.shouldLog(.Fatal)) self.loggerWithLevel(.Fatal) else logz.noop;
	}

	pub fn logger(self: *Self) logz.Logger {
		const kv = self.acquire() orelse return logz.noop;
		return logz.Logger{.pool = self, .inner = .{.kv = kv}};
	}

	pub fn loggerL(self: *Self, lvl: logz.Level) logz.Logger {
		const kv = self.acquire() orelse return logz.noop;
		var l = logz.Logger{.pool = self, .inner = .{.kv = kv}};
		_ = l.level(lvl);
		return l;
	}

	pub fn shouldLog(self: *Self, level: logz.Level) bool {
		return @intFromEnum(level) >= self.level;
	}

	fn loggerWithLevel(self: *Self, lvl: logz.Level) logz.Logger {
		var kv = self.acquire() orelse return logz.noop;
		kv.level(lvl);
		return logz.Logger{.pool = self, .inner = .{.kv = kv}};
	}
};

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
		try t.expectString("@ts=9999999999999 @l=DEBUG a=1\n", out.items);

		out.clearRetainingCapacity();
		try p.info().int("a", 2).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=INFO a=2\n", out.items);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=WARN a=333\n", out.items);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.items);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.items);
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
		try t.expectString("@ts=9999999999999 @l=INFO a=2\n", out.items);

		out.clearRetainingCapacity();
		try p.warn().int("a", 333).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=WARN a=333\n", out.items);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.items);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.items);
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
		try t.expectString("@ts=9999999999999 @l=WARN a=333\n", out.items);

		out.clearRetainingCapacity();
		try p.err().int("a", 4444).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.items);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.items);
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
		try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.items);

		out.clearRetainingCapacity();
		try p.fatal().string("aaa", "zzzz").logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.items);
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
		try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.items);
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

test "pool: logger" {
	var min_config = Config{.pool_size = 1, .max_size = 100};
	var out = std.ArrayList(u8).init(t.allocator);
	defer out.deinit();

	{
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try p.logger().string("hero", "teg").logTo(out.writer());
		try t.expectString("@ts=9999999999999 hero=teg\n", out.items);
	}

	{
		out.clearRetainingCapacity();
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		var l = p.logger().string("hero", "teg");
		try l.logTo(out.writer());
		try t.expectString("@ts=9999999999999 hero=teg\n", out.items);
	}

	{
		// delayed level, above min
		out.clearRetainingCapacity();
		min_config.level = .Warn;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		var l = p.logger().string("hero", "teg");
		_ = l.level(logz.Level.Warn);
		try l.logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=WARN hero=teg\n", out.items);
	}

	{
		// delayed level, under min
		out.clearRetainingCapacity();
		min_config.level = .Warn;
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		var l = p.logger().string("hero", "teg");
		l.level(logz.Level.Info).done();
		try l.logTo(out.writer());
		try t.expectString("", out.items);
	}
}

test "pool: loggerL" {
	var min_config = Config{.pool_size = 1, .max_size = 100};
	var out = std.ArrayList(u8).init(t.allocator);
	defer out.deinit();

	{
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		try p.loggerL(logz.Warn).string("hero", "teg").logTo(out.writer());

		try t.expectString("@ts=9999999999999 @l=WARN hero=teg\n", out.items);
	}

	{
		out.clearRetainingCapacity();
		var p = try Pool.init(t.allocator, min_config);
		defer p.deinit();

		var logger = p.loggerL(logz.Warn).string("hero", "teg");
		logger.level(.Error).done();
		try logger.logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=ERROR hero=teg\n", out.items);
	}
}

test "pool: prefix" {
	var out = std.ArrayList(u8).init(t.allocator);
	defer out.deinit();

	var p = try Pool.init(t.allocator, .{.pool_size = 2, .max_size = 100, .prefix = "Keemun"});
	defer p.deinit();

	// we want to make sure dynamically allocated loggers also get the prefix
	var l1 = p.info().int("id", 1);
	var l2 = p.info().int("id", 2);
	var l3 = p.info().int("id", 3);

	try l1.logTo(out.writer());
	try t.expectString("Keemun @ts=9999999999999 @l=INFO id=1\n", out.items);

	out.clearRetainingCapacity();
	try l2.logTo(out.writer());
	try t.expectString("Keemun @ts=9999999999999 @l=INFO id=2\n", out.items);

	out.clearRetainingCapacity();
	try l3.logTo(out.writer());
	try t.expectString("Keemun @ts=9999999999999 @l=INFO id=3\n", out.items);

	// and the prefix remains after being released and re-acquired
	out.clearRetainingCapacity();
	try p.info().int("id", 4).logTo(out.writer());
	try t.expectString("Keemun @ts=9999999999999 @l=INFO id=4\n", out.items);

	out.clearRetainingCapacity();
	try p.info().int("id", 5).logTo(out.writer());
	try t.expectString("Keemun @ts=9999999999999 @l=INFO id=5\n", out.items);
}

test "pool: multiuse" {
	var out = std.ArrayList(u8).init(t.allocator);
	defer out.deinit();

	var p = try Pool.init(t.allocator, .{.pool_size = 2, .max_size = 100});
	defer p.deinit();

	{
		// no extra data (why?)
		var logger = p.loggerL(.Info).multiuse();
		try logger.int("x", 4).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=INFO x=4\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

		out.clearRetainingCapacity();
		_ = logger.int("x", 5);
		logger.level(.Warn).done();
		try logger.logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=WARN x=5\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
		logger.release();
	}

	{
		out.clearRetainingCapacity();
		var logger = p.loggerL(.Info).stringSafe("rid", "req1").multiuse();
		try logger.int("x", 4).logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=INFO rid=req1 x=4\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

		out.clearRetainingCapacity();
		_ = logger.int("x", 5);
		logger.level(.Warn).done();
		try logger.logTo(out.writer());
		try t.expectString("@ts=9999999999999 @l=WARN rid=req1 x=5\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
		logger.release();
	}
}

test "pool: multiuse with prefix" {
	var out = std.ArrayList(u8).init(t.allocator);
	defer out.deinit();

	var p = try Pool.init(t.allocator, .{.pool_size = 2, .max_size = 100, .prefix = "silver=needle"});
	defer p.deinit();

	{
		// no extra data (why?)
		var logger = p.loggerL(.Info).multiuse();
		try logger.int("x", 4).logTo(out.writer());
		try t.expectString("silver=needle @ts=9999999999999 @l=INFO x=4\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

		out.clearRetainingCapacity();
		_ = logger.int("x", 5);
		_ = logger.level(.Warn);
		try logger.logTo(out.writer());
		try t.expectString("silver=needle @ts=9999999999999 @l=WARN x=5\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
		logger.release();
	}

	{
		out.clearRetainingCapacity();
		var logger = p.loggerL(.Info).stringSafe("rid", "req1").multiuse();
		try logger.int("x", 4).logTo(out.writer());
		try t.expectString("silver=needle @ts=9999999999999 @l=INFO rid=req1 x=4\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

		out.clearRetainingCapacity();
		_ = logger.int("x", 5);
		logger.level(.Warn).done();
		try logger.logTo(out.writer());
		try t.expectString("silver=needle @ts=9999999999999 @l=WARN rid=req1 x=5\n", out.items);
		try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
		logger.release();
	}
}
