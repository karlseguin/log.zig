const std = @import("std");
const logz = @import("logz.zig");

const Io = std.Io;
const Logger = logz.Logger;

const Json = @import("json.zig").Json;
const LogFmt = @import("logfmt.zig").LogFmt;
const Config = @import("config.zig").Config;
const BufferPool = @import("buffer.zig").Pool;
const metrics = @import("metrics.zig");

const Allocator = std.mem.Allocator;

pub const Pool = struct {
    io: Io,
    level: u3,
    config: Config,

    // Passed to the loggers to coordinate writes to the output
    log_mutex: Io.Mutex,

    // Used by the pool when acquiring/releasing a logger
    pool_mutex: Io.Mutex,

    available: usize,
    loggers: []Logger,
    allocator: Allocator,
    strategy: Config.PoolStrategy,
    buffer_pool: BufferPool,

    file: Io.File,
    // The individual writers ensure writes are protected by the pool_mutex
    writer: Io.File.Writer,
    writer_buf: [4096]u8 = undefined,

    pub fn init(io: Io, allocator: Allocator, config: Config) !*Pool {
        const size = config.pool_size;

        const loggers = try allocator.alloc(Logger, size);
        errdefer allocator.free(loggers);

        var buffer_pool = try BufferPool.init(io, allocator, &config);
        errdefer buffer_pool.deinit();

        const pool = try allocator.create(Pool);
        errdefer allocator.destroy(pool);

        const file = switch (config.output) {
            .stderr => Io.File.stderr(),
            .stdout => Io.File.stdout(),
            .file => |path| blk: {
                // createFile with truncate=false still truncates the file
                // https://github.com/ziglang/zig/issues/14375
                // Yes, this is still true in 0.16 as far as I can tell.

                var f = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |open_err| switch (open_err) {
                    error.FileNotFound => break :blk try Io.Dir.cwd().createFile(io, path, .{}),
                    else => return open_err,
                };

                const stat = try f.stat(io);
                var file_writer = f.writer(io, &.{});
                try file_writer.seekTo(stat.size);
                break :blk f;
            },
        };

        pool.* = .{
            .io = io,
            .file = file,
            .config = config,
            .loggers = loggers,
            .available = size,
            .log_mutex = .init,
            .pool_mutex = .init,
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .strategy = config.pool_strategy,
            .level = @intFromEnum(config.level),
            .writer = undefined,
        };

        pool.writer = pool.file.writer(io, &pool.writer_buf);

        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                pool.destroyLogger(loggers[i]);
            }
        }

        for (0..size) |i| {
            loggers[i] = try pool.createLogger();
            initialized += 1;
        }

        return pool;
    }

    pub fn deinit(self: *Pool) void {
        const allocator = self.allocator;
        for (self.loggers) |l| {
            self.destroyLogger(l);
        }
        self.buffer_pool.deinit();
        allocator.free(self.loggers);

        const handle = self.file.handle;
        if (handle != Io.File.stderr().handle and handle != Io.File.stdout().handle) {
            self.file.close(self.io);
        }

        allocator.destroy(self);
    }

    pub fn acquire(self: *Pool) Logger {
        const io = self.io;
        self.pool_mutex.lockUncancelable(io);

        const loggers = self.loggers;
        const available = self.available;
        if (available == 0) {
            // dont hold the lock over factory
            self.pool_mutex.unlock(io);

            metrics.poolEmpty();
            if (self.strategy == .noop) {
                return logz.noop;
            }

            const l = self.createLogger() catch |e| {
                logDynamicAllocationFailure(e);
                return logz.noop;
            };
            return l;
        }
        const index = available - 1;
        const l = loggers[index];
        self.available = index;
        self.pool_mutex.unlock(io);
        return l;
    }

    pub fn release(self: *Pool, l: Logger) void {
        const io = self.io;
        l.reset();
        self.pool_mutex.lockUncancelable(io);

        var loggers = self.loggers;
        const available = self.available;
        if (available == loggers.len) {
            self.pool_mutex.unlock(io);
            self.destroyLogger(l);
            return;
        }
        loggers[available] = l;
        self.available = available + 1;
        self.pool_mutex.unlock(io);
    }

    pub fn debug(self: *Pool) Logger {
        return if (self.shouldLog(.Debug)) self.loggerWithLevel(.Debug) else logz.noop;
    }

    pub fn info(self: *Pool) Logger {
        return if (self.shouldLog(.Info)) self.loggerWithLevel(.Info) else logz.noop;
    }

    pub fn warn(self: *Pool) Logger {
        return if (self.shouldLog(.Warn)) self.loggerWithLevel(.Warn) else logz.noop;
    }

    pub fn err(self: *Pool) Logger {
        return if (self.shouldLog(.Error)) self.loggerWithLevel(.Error) else logz.noop;
    }

    pub fn fatal(self: *Pool) Logger {
        return if (self.shouldLog(.Fatal)) self.loggerWithLevel(.Fatal) else logz.noop;
    }

    pub fn logger(self: *Pool) Logger {
        if (self.level == @intFromEnum(logz.Level.None)) return logz.noop;
        return self.acquire();
    }

    pub fn loggerL(self: *Pool, lvl: logz.Level) Logger {
        var l = self.acquire();
        _ = l.level(lvl);
        return l;
    }

    pub fn shouldLog(self: *Pool, level: logz.Level) bool {
        return @intFromEnum(level) >= self.level;
    }

    fn loggerWithLevel(self: *Pool, lvl: logz.Level) Logger {
        var l = self.acquire();
        _ = l.level(lvl);
        return l;
    }

    pub fn createLogger(self: *Pool) !Logger {
        const allocator = self.allocator;

        switch (self.config.encoding) {
            .logfmt => {
                const logfmt = try allocator.create(LogFmt);
                errdefer allocator.destroy(logfmt);

                logfmt.* = try LogFmt.init(allocator, self);
                return .{ .pool = self, .inner = .{ .logfmt = logfmt } };
            },
            .json => {
                const json = try allocator.create(Json);
                errdefer allocator.destroy(json);

                json.* = try Json.init(allocator, self);
                return .{ .pool = self, .inner = .{ .json = json } };
            },
        }
    }

    pub fn destroyLogger(self: *Pool, l: Logger) void {
        switch (l.inner) {
            .logfmt => |logfmt| {
                logfmt.deinit(self.allocator);
                self.allocator.destroy(logfmt);
            },
            .json => |json| {
                json.deinit(self.allocator);
                self.allocator.destroy(json);
            },
            else => unreachable,
        }
    }
};

fn logDynamicAllocationFailure(err: anyerror) void {
    const msg = "logz: logged pool is empty and we failed to dynamically allowcate a new loggger. Log will be dropped. Error was: {}";
    std.log.err(msg, .{err});
}

const t = @import("t.zig");
test "pool: shouldLog" {
    var min_config = Config{ .pool_size = 1, .buffer_size = 1 };

    {
        min_config.level = .Debug;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try t.expectEqual(true, p.shouldLog(.Debug));
        try t.expectEqual(true, p.shouldLog(.Info));
        try t.expectEqual(true, p.shouldLog(.Warn));
        try t.expectEqual(true, p.shouldLog(.Error));
        try t.expectEqual(true, p.shouldLog(.Fatal));
    }

    {
        min_config.level = .Info;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try t.expectEqual(false, p.shouldLog(.Debug));
        try t.expectEqual(true, p.shouldLog(.Info));
        try t.expectEqual(true, p.shouldLog(.Warn));
        try t.expectEqual(true, p.shouldLog(.Error));
        try t.expectEqual(true, p.shouldLog(.Fatal));
    }

    {
        min_config.level = .Warn;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try t.expectEqual(false, p.shouldLog(.Debug));
        try t.expectEqual(false, p.shouldLog(.Info));
        try t.expectEqual(true, p.shouldLog(.Warn));
        try t.expectEqual(true, p.shouldLog(.Error));
        try t.expectEqual(true, p.shouldLog(.Fatal));
    }

    {
        min_config.level = .Error;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try t.expectEqual(false, p.shouldLog(.Debug));
        try t.expectEqual(false, p.shouldLog(.Info));
        try t.expectEqual(false, p.shouldLog(.Warn));
        try t.expectEqual(true, p.shouldLog(.Error));
        try t.expectEqual(true, p.shouldLog(.Fatal));
    }

    {
        min_config.level = .Fatal;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try t.expectEqual(false, p.shouldLog(.Debug));
        try t.expectEqual(false, p.shouldLog(.Info));
        try t.expectEqual(false, p.shouldLog(.Warn));
        try t.expectEqual(false, p.shouldLog(.Error));
        try t.expectEqual(true, p.shouldLog(.Fatal));
    }

    {
        min_config.level = .None;
        var p = try Pool.init(t.io, t.allocator, min_config);
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
    const min_config = Config{ .pool_size = 2, .buffer_size = 1 };
    var p = try Pool.init(t.io, t.allocator, min_config);
    defer p.deinit();

    const l1a = p.acquire();
    const l2a = p.acquire();
    const l3a = p.acquire(); // this should be dynamically generated

    try t.expectEqual(false, l1a.inner.logfmt == l2a.inner.logfmt);
    try t.expectEqual(false, l2a.inner.logfmt == l3a.inner.logfmt);

    l1a.release();

    const l1b = p.acquire();
    try t.expectEqual(true, l1a.inner.logfmt == l1b.inner.logfmt);

    l3a.release();
    l2a.release();
    l1b.release();
}

test "pool: empty noop" {
    // not 100% sure this is testing exactly what I want, but it's ....something ?
    const min_config = Config{ .pool_size = 2, .buffer_size = 1, .pool_strategy = .noop };
    var p = try Pool.init(t.io, t.allocator, min_config);
    defer p.deinit();

    const l1a = p.acquire();
    const l2a = p.acquire();
    const l3a = p.acquire(); // this should be noop

    try t.expectEqual(false, l1a.inner.logfmt == l2a.inner.logfmt);
    try t.expectEqual(.noop, std.meta.activeTag(l3a.inner));

    l1a.release();

    const l1b = p.acquire();
    try t.expectEqual(true, l1a.inner.logfmt == l1b.inner.logfmt);

    l3a.release();
    l2a.release();
    l1b.release();
}

test "pool: logger" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var min_config = Config{ .pool_size = 1, .buffer_size = 100 };
    {
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try p.logger().string("hero", "teg").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 hero=teg\n", out.written());
    }

    {
        out.clearRetainingCapacity();
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        var l = p.logger().string("hero", "teg");
        try l.logTo(&out.writer);
        try t.expectString("@ts=9999999999999 hero=teg\n", out.written());
    }

    {
        // delayed level, above min
        out.clearRetainingCapacity();
        min_config.level = .Warn;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        var l = p.logger().string("hero", "teg");
        _ = l.level(logz.Level.Warn);
        try l.logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=WARN hero=teg\n", out.written());
    }

    {
        // delayed level, under min
        out.clearRetainingCapacity();
        min_config.level = .Warn;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        var l = p.logger().string("hero", "teg");
        l.level(logz.Level.Info).done();
        try l.logTo(&out.writer);
        try t.expectString("", out.written());
    }
}

test "pool: loggerL" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    const min_config = Config{ .pool_size = 1, .buffer_size = 100 };
    {
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try p.loggerL(.Warn).string("hero", "teg").logTo(&out.writer);

        try t.expectString("@ts=9999999999999 @l=WARN hero=teg\n", out.written());
    }

    {
        out.clearRetainingCapacity();
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        var logger = p.loggerL(.Warn).string("hero", "teg");
        logger.level(.Error).done();
        try logger.logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=ERROR hero=teg\n", out.written());
    }
}

test "pool: logfmt log" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var min_config = Config{ .pool_size = 1, .buffer_size = 100 };
    {
        min_config.level = .Debug;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=DEBUG a=1\n", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=INFO a=2\n", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=WARN a=333\n", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.written());
    }

    {
        min_config.level = .Info;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        out.clearRetainingCapacity();
        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=INFO a=2\n", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=WARN a=333\n", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.written());
    }

    {
        min_config.level = .Warn;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        out.clearRetainingCapacity();
        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=WARN a=333\n", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.written());
    }

    {
        min_config.level = .Error;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        out.clearRetainingCapacity();
        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=ERROR a=4444\n", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.written());
    }

    {
        min_config.level = .Fatal;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        out.clearRetainingCapacity();
        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=FATAL aaa=zzzz\n", out.written());

        out.clearRetainingCapacity();
        try p.logger().string("aaa", "zz2zz").logTo(&out.writer);
        try t.expectString("@ts=9999999999999 aaa=zz2zz\n", out.written());
    }

    {
        min_config.level = .None;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        out.clearRetainingCapacity();
        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("", out.written());
    }
}

test "pool: logfmt prefix" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var p = try Pool.init(t.io, t.allocator, .{ .pool_size = 2, .buffer_size = 100, .prefix = "Keemun " });
    defer p.deinit();

    // we want to make sure dynamically allocated loggers also get the prefix
    var l1 = p.info().int("id", 1);
    var l2 = p.info().int("id", 2);
    var l3 = p.info().int("id", 3);

    try l1.logTo(&out.writer);
    try t.expectString("Keemun @ts=9999999999999 @l=INFO id=1\n", out.written());

    out.clearRetainingCapacity();
    try l2.logTo(&out.writer);
    try t.expectString("Keemun @ts=9999999999999 @l=INFO id=2\n", out.written());

    out.clearRetainingCapacity();
    try l3.logTo(&out.writer);
    try t.expectString("Keemun @ts=9999999999999 @l=INFO id=3\n", out.written());

    // and the prefix remains after being released and re-acquired
    out.clearRetainingCapacity();
    try p.info().int("id", 4).logTo(&out.writer);
    try t.expectString("Keemun @ts=9999999999999 @l=INFO id=4\n", out.written());

    out.clearRetainingCapacity();
    try p.info().int("id", 5).logTo(&out.writer);
    try t.expectString("Keemun @ts=9999999999999 @l=INFO id=5\n", out.written());
}

test "pool: logfmt multiuse" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var p = try Pool.init(t.io, t.allocator, .{ .pool_size = 2, .buffer_size = 100 });
    defer p.deinit();

    {
        // no extra data (why?)
        var logger = p.loggerL(.Info).multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=INFO x=4\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        logger.level(.Warn).done();
        try logger.logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=WARN x=5\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }

    {
        out.clearRetainingCapacity();
        var logger = p.loggerL(.Info).stringSafe("rid", "req1").multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=INFO rid=req1 x=4\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        logger.level(.Warn).done();
        try logger.logTo(&out.writer);
        try t.expectString("@ts=9999999999999 @l=WARN rid=req1 x=5\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }
}

test "pool: logfmt multiuse with prefix" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var p = try Pool.init(t.io, t.allocator, .{ .pool_size = 2, .buffer_size = 100, .prefix = "silver=needle " });
    defer p.deinit();

    {
        // no extra data (why?)
        var logger = p.loggerL(.Info).multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("silver=needle @ts=9999999999999 @l=INFO x=4\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        _ = logger.level(.Warn);
        try logger.logTo(&out.writer);
        try t.expectString("silver=needle @ts=9999999999999 @l=WARN x=5\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }

    {
        out.clearRetainingCapacity();
        var logger = p.loggerL(.Info).stringSafe("rid", "req1").multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("silver=needle @ts=9999999999999 @l=INFO rid=req1 x=4\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        logger.level(.Warn).done();
        try logger.logTo(&out.writer);
        try t.expectString("silver=needle @ts=9999999999999 @l=WARN rid=req1 x=5\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }
}

test "pool: json log" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var min_config = Config{ .pool_size = 1, .buffer_size = 100, .encoding = .json };
    {
        min_config.level = .Debug;
        var p = try Pool.init(t.io, t.allocator, min_config);
        defer p.deinit();

        try p.debug().int("a", 1).logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"DEBUG\",\"a\":1}\n", out.written());

        out.clearRetainingCapacity();
        try p.info().int("a", 2).logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"INFO\",\"a\":2}\n", out.written());

        out.clearRetainingCapacity();
        try p.warn().int("a", 333).logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"WARN\",\"a\":333}\n", out.written());

        out.clearRetainingCapacity();
        try p.err().int("a", 4444).logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"ERROR\",\"a\":4444}\n", out.written());

        out.clearRetainingCapacity();
        try p.fatal().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"FATAL\",\"aaa\":\"zzzz\"}\n", out.written());

        out.clearRetainingCapacity();
        try p.logger().string("aaa", "zzzz").logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"aaa\":\"zzzz\"}\n", out.written());
    }
}

test "pool: json prefix" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var p = try Pool.init(t.io, t.allocator, .{ .pool_size = 2, .buffer_size = 100, .encoding = .json, .prefix = "{\"x\": 1," });
    defer p.deinit();

    // we want to make sure dynamically allocated loggers also get the prefix
    var l1 = p.info().int("id", 1);
    var l2 = p.info().int("id", 2);
    var l3 = p.info().int("id", 3);

    try l1.logTo(&out.writer);
    try t.expectString("{\"x\": 1, \"@ts\":9999999999999,\"@l\":\"INFO\",\"id\":1}\n", out.written());

    out.clearRetainingCapacity();
    try l2.logTo(&out.writer);
    try t.expectString("{\"x\": 1, \"@ts\":9999999999999,\"@l\":\"INFO\",\"id\":2}\n", out.written());

    out.clearRetainingCapacity();
    try l3.logTo(&out.writer);
    try t.expectString("{\"x\": 1, \"@ts\":9999999999999,\"@l\":\"INFO\",\"id\":3}\n", out.written());

    // and the prefix remains after being released and re-acquired
    out.clearRetainingCapacity();
    try p.info().int("id", 4).logTo(&out.writer);
    try t.expectString("{\"x\": 1, \"@ts\":9999999999999,\"@l\":\"INFO\",\"id\":4}\n", out.written());

    out.clearRetainingCapacity();
    try p.info().int("id", 5).logTo(&out.writer);
    try t.expectString("{\"x\": 1, \"@ts\":9999999999999,\"@l\":\"INFO\",\"id\":5}\n", out.written());
}

test "pool: json multiuse" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var p = try Pool.init(t.io, t.allocator, .{ .pool_size = 2, .encoding = .json, .buffer_size = 100 });
    defer p.deinit();

    {
        // no extra data (why?)
        var logger = p.loggerL(.Info).multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"INFO\",\"x\":4}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        logger.level(.Warn).done();
        try logger.logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"WARN\",\"x\":5}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }

    {
        out.clearRetainingCapacity();
        var logger = p.loggerL(.Info).stringSafe("rid", "req1").multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"INFO\",\"rid\":\"req1\",\"x\":4}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        logger.level(.Warn).done();
        try logger.logTo(&out.writer);
        try t.expectString("{\"@ts\":9999999999999,\"@l\":\"WARN\",\"rid\":\"req1\",\"x\":5}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }
}

test "pool: json multiuse with prefix" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    var p = try Pool.init(t.io, t.allocator, .{ .pool_size = 2, .buffer_size = 100, .encoding = .json, .prefix = "silver=needle " });
    defer p.deinit();

    // the caller is responsible for making sure the prefix begins a valid json object

    {
        // no extra data (why?)
        var logger = p.loggerL(.Info).multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("silver=needle  \"@ts\":9999999999999,\"@l\":\"INFO\",\"x\":4}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        _ = logger.level(.Warn);
        try logger.logTo(&out.writer);
        try t.expectString("silver=needle  \"@ts\":9999999999999,\"@l\":\"WARN\",\"x\":5}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }

    {
        out.clearRetainingCapacity();
        var logger = p.loggerL(.Info).stringSafe("rid", "req1").multiuse();
        try logger.int("x", 4).logTo(&out.writer);
        try t.expectString("silver=needle  \"@ts\":9999999999999,\"@l\":\"INFO\",\"rid\":\"req1\",\"x\":4}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool

        out.clearRetainingCapacity();
        _ = logger.int("x", 5);
        logger.level(.Warn).done();
        try logger.logTo(&out.writer);
        try t.expectString("silver=needle  \"@ts\":9999999999999,\"@l\":\"WARN\",\"rid\":\"req1\",\"x\":5}\n", out.written());
        try t.expectEqual(@as(usize, 1), p.available); // logger hasn't gone back in the pool
        logger.release();
    }
}

test "pool: file out" {
    Io.Dir.cwd().deleteFile(t.io, "test.out") catch {};
    defer Io.Dir.cwd().deleteFile(t.io, "test.out") catch {};

    {
        var p = try Pool.init(t.io, t.allocator, .{
            .pool_size = 2,
            .buffer_size = 100,
            .output = .{ .file = "test.out" },
        });
        defer p.deinit();

        p.info().int("over", 9000).log();
        p.info().string("hello", "world").int("uid", -32).log();

        const data = try Io.Dir.cwd().readFileAlloc(t.io, "test.out", t.allocator, .limited(1000));
        defer t.allocator.free(data);

        try t.expectString(
            \\@ts=9999999999999 @l=INFO over=9000
            \\@ts=9999999999999 @l=INFO hello=world uid=-32
            \\
        , data);
    }

    // {
    //     // make sure it appends
    //     var p = try Pool.init(t.io, t.allocator, .{
    //         .pool_size = 2,
    //         .buffer_size = 100,
    //         .output = .{ .file = "test.out" },
    //     });
    //     defer p.deinit();

    //     p.err().boolean("goodnight", true).log();

    //     const data = try Io.Dir.cwd().readFileAlloc(t.io, "test.out", t.allocator, .limited(1000));
    //     defer t.allocator.free(data);

    //     try t.expectString(
    //         \\@ts=9999999999999 @l=INFO over=9000
    //         \\@ts=9999999999999 @l=INFO hello=world uid=-32
    //         \\@ts=9999999999999 @l=ERROR goodnight=Y
    //         \\
    //     , data);
    // }
}
