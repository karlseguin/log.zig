const std = @import("std");
const logz = @import("logz.zig");

const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;
const Buffer = @import("buffer.zig").Buffer;

const File = std.fs.File;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad.Encoder;

const META_LEN = "@ts=9999999999999 @L=ERROR ".len;

const t = @import("t.zig");
const timestamp = if (t.is_test) t.timestamp else std.time.milliTimestamp;

pub const LogFmt = struct {
    out: File,

    lvl: logz.Level,

    // space for a configured prefix + the @ts=$time and @l=$level meta fields
    meta: []u8,

    buffer: Buffer,

    multiuse_length: ?usize,

    mutex: *Mutex,

    pub fn init(allocator: Allocator, pool: *Pool) !LogFmt {
        var buffer = try pool.buffer_pool.create();
        errdefer buffer.deinit();

        const meta_len = META_LEN + if (pool.config.prefix) |p| p.len else 0;

        const meta = try allocator.alloc(u8, meta_len);
        errdefer allocator.free(meta);

        if (pool.config.prefix) |prefix| {
            @memcpy(meta[0..prefix.len], prefix);
        }

        return .{
            .lvl = .None,
            .meta = meta,
            .buffer = buffer,
            .out = pool.file,
            .multiuse_length = null,
            .mutex = &pool.log_mutex,
        };
    }

    pub fn deinit(self: *LogFmt, allocator: Allocator) void {
        allocator.free(self.meta);
        self.buffer.deinit();
    }

    pub fn multiuse(self: *LogFmt) void {
        self.multiuse_length = self.buffer.pos;
    }

    pub fn reset(self: *LogFmt) void {
        self.lvl = .None;
        self.multiuse_length = null;
        self.buffer.reset(0);
    }

    pub fn reuse(self: *LogFmt) void {
        self.lvl = .None;
        self.buffer.reset(self.multiuse_length orelse 0);
    }

    pub fn level(self: *LogFmt, lvl: logz.Level) void {
        self.lvl = lvl;
    }

    pub fn ctx(self: *LogFmt, value: []const u8) void {
        self.string("@ctx", value);
    }

    pub fn src(self: *LogFmt, value: std.builtin.SourceLocation) void {
        self.string("@src.file", value.file);
        self.string("@src.fn", value.fn_name);
        self.int("@src.line", value.line);
    }

    pub fn string(self: *LogFmt, key: []const u8, nvalue: ?[]const u8) void {
        const value = nvalue orelse {
            self.writeNull(key);
            return;
        };

        const ea = escapeAnalysis(value);

        if (ea.needed == false) {
            self.writeKeyValue(key, value);
            return;
        }

        const encoded_len = value.len + ea.count;

        // + 1 for the equal
        // + 2 for the quotes
        // + 1 for the trailing space
        var aw = self.buffer.attributeWriter(4 + key.len + encoded_len, true) orelse return;
        aw.writeAllAll(key, "=\"");
        self.writeEscapeValue(value, ea.count) catch {
            aw.rollback();
            return;
        };
        aw.writeAll("\" ");
        aw.done();
    }

    pub fn fmt(self: *LogFmt, key: []const u8, comptime format: []const u8, values: anytype) void {
        const rewind = self.startKeyValue(key) orelse return;

        var buffer = &self.buffer;

        buffer.writeByte('"') catch {
            buffer.rollback(rewind);
            return;
        };

        std.fmt.format(FmtWriter{ .logfmt = self }, format, values) catch {
            buffer.rollback(rewind);
            return;
        };

        buffer.writeAll("\" ") catch {
            buffer.rollback(rewind);
            return;
        };
    }

    pub fn stringZ(self: *LogFmt, key: []const u8, nvalue: ?[*:0]const u8) void {
        if (nvalue == null) {
            self.writeNull(key);
            return;
        }
        self.string(key, std.mem.span(nvalue));
    }

    // cases where the caller is sure value does not need to be encoded
    pub fn stringSafe(self: *LogFmt, key: []const u8, nvalue: ?[]const u8) void {
        const value = nvalue orelse {
            self.writeNull(key);
            return;
        };
        self.writeKeyValue(key, value);
    }

    // cases where the caller is sure value does not need to be encoded
    pub fn stringSafeZ(self: *LogFmt, key: []const u8, value: ?[*:0]const u8) void {
        if (value) |v| {
            self.writeKeyValue(key, std.mem.span(v));
        } else {
            self.writeNull(key);
        }
    }

    pub fn int(self: *LogFmt, key: []const u8, value: anytype) void {
        const n = switch (@typeInfo(@TypeOf(value))) {
            .optional => blk: {
                if (value) |v| {
                    break :blk v;
                }
                self.writeNull(key);
                return;
            },
            .null => {
                self.writeNull(key);
                return;
            },
            else => value,
        };

        const rewind = self.startKeyValue(key) orelse return;
        var buffer = &self.buffer;
        std.fmt.formatInt(n, 10, .lower, .{}, buffer) catch {
            self.buffer.rollback(rewind);
            return;
        };
        buffer.writeByte(' ') catch self.buffer.rollback(rewind);
    }

    pub fn float(self: *LogFmt, key: []const u8, value: anytype) void {
        const f = switch (@typeInfo(@TypeOf(value))) {
            .optional => blk: {
                if (value) |v| {
                    break :blk v;
                }
                self.writeNull(key);
                return;
            },
            .null => {
                self.writeNull(key);
                return;
            },
            else => value,
        };

        const rewind = self.startKeyValue(key) orelse return;
        var buffer = &self.buffer;
        std.fmt.formatType(f, "d", .{}, buffer.writer(), 0) catch {
            self.buffer.rollback(rewind);
            return;
        };
        buffer.writeByte(' ') catch self.buffer.rollback(rewind);
    }

    pub fn boolean(self: *LogFmt, key: []const u8, value: anytype) void {
        const b = switch (@typeInfo(@TypeOf(value))) {
            .optional => blk: {
                if (value) |v| {
                    break :blk v;
                }
                self.writeNull(key);
                return;
            },
            .null => {
                self.writeNull(key);
                return;
            },
            else => value,
        };

        self.writeKeyValue(key, if (b) "Y" else "N");
    }

    pub fn binary(self: *LogFmt, key: []const u8, nvalue: ?[]const u8) void {
        const value = nvalue orelse {
            self.writeNull(key);
            return;
        };

        // + 2 for the '=' and the trailing space
        var aw = self.buffer.attributeWriter(2 + key.len + b64.calcSize(value.len), true) orelse return;
        aw.writeAllB(key, '=');

        var pos: usize = 0;
        var end: usize = 12;
        var scratch: [16]u8 = undefined;
        while (end < value.len) {
            _ = b64.encode(&scratch, value[pos..end]);
            pos = end;
            end += 12;
            aw.writeAll(&scratch);
        }

        if (pos < value.len) {
            const leftover = b64.encode(&scratch, value[pos..]);
            aw.writeAll(leftover);
        }
        aw.writeByte(' ');
        aw.done();
    }

    pub fn err(self: *LogFmt, value: anyerror) void {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .optional => {
                if (value) |v| {
                    self.string("@err", @errorName(v));
                } else {
                    self.writeNull("@err");
                }
            },
            else => self.string("@err", @errorName(value)),
        }
    }

    pub fn errK(self: *LogFmt, key: []const u8, value: anyerror) void {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .optional => {
                if (value) |v| {
                    self.string(key, @errorName(v));
                } else {
                    self.writeNull(key);
                }
            },
            else => self.string(key, @errorName(value)),
        }
    }

    pub fn tryLog(self: *LogFmt) !void {
        try self.logTo(self.out);
    }

    pub fn log(self: *LogFmt) void {
        self.logTo(self.out) catch |e| {
            const msg = "logz: Failed to write log. Log will be dropped. Error was: {}";
            std.log.err(msg, .{e});
        };
    }

    pub fn logTo(self: *LogFmt, out: anytype) !void {
        const buffer = &self.buffer;
        const pos = buffer.pos;

        if (pos == 0) {
            // nothing was logged (or nothing fit in the buffers)
            return;
        }

        const meta = self.meta;
        const meta_len = blk: {
            // append timestamp to our meta
            const prefix_len = meta.len - META_LEN;
            const meta_buf = meta[prefix_len..];

            @memcpy(meta_buf[0..4], "@ts=");
            _ = std.fmt.formatIntBuf(meta_buf[4..], timestamp(), 10, .lower, .{});

            switch (self.lvl) {
                .Debug => {
                    @memcpy(meta_buf[17..], " @l=DEBUG ");
                    break :blk meta.len;
                },
                .Info => {
                    @memcpy(meta_buf[17..26], " @l=INFO ");
                    break :blk meta.len - 1;
                },
                .Warn => {
                    @memcpy(meta_buf[17..26], " @l=WARN ");
                    break :blk meta.len - 1;
                },
                .Error => {
                    @memcpy(meta_buf[17..], " @l=ERROR ");
                    break :blk meta.len;
                },
                .Fatal => {
                    @memcpy(meta_buf[17..], " @l=FATAL ");
                    break :blk meta.len;
                },
                else => {
                    meta_buf[17] = ' ';
                    break :blk meta.len - 9;
                },
            }
        };

        const buf = buffer.buf;
        buf[pos - 1] = '\n';

        const static = buffer.static;

        self.mutex.lock();
        defer self.mutex.unlock();

        try out.writeAll(meta[0..meta_len]);
        if (buf.ptr != static.ptr) {
            // if we had to get a larger buffer, than static should be filled
            try out.writeAll(static);
        }

        // we should always write a trailing space, the last of which, we can
        // now replace with a newline
        try out.writeAll(buf[0..pos]);
    }

    fn startKeyValue(self: *LogFmt, key: []const u8) ?Buffer.RewindState {
        var buffer = &self.buffer;

        const rewind = buffer.begin();
        switch (buffer.sizeCheck(key.len + 2)) {
            .none => return null,
            .buf => {
                // optimize this common case
                buffer.writeAllBuf(key);
                buffer.writeByteBuf('=');
            },
            .acquire_large => {
                buffer.writeAll(key) catch return null;
                buffer.writeByte('=') catch {
                    buffer.rollback(rewind);
                    return null;
                };
            },
        }

        return rewind;
    }

    fn writeNull(self: *LogFmt, key: []const u8) void {
        self.writeKeyValue(key, "null");
    }

    fn writeEscapeValue(self: *LogFmt, value: []const u8, escape_count: usize) !void {
        var buffer = &self.buffer;

        // every escape sequence requires 1 extra character
        const to_write = value.len + escape_count;
        switch (buffer.sizeCheck(to_write)) {
            .buf => {
                var buf = buffer.buf;
                const pos = buffer.pos;
                _ = writeEscapeInto(buf[pos..], value);
                buffer.pos = pos + to_write;
            },
            .acquire_large => |available| {
                // We'll write what we can into the static buffer, and then write the
                // rest into a larger buffer. This includes possibly splitting an escape
                // sequence, so that, for example, the \\ is the last byte of the static
                // buffer, and the 'n' is the first byte of larger. This is necessary
                // because other parts of the code assume static is _always_ fully filled
                // if a larger buffer was acquired.
                const larger = (buffer.pool.acquireLarge() catch return error.NoSpaceLeft) orelse return error.NoSpaceLeft;
                var written = WriteEscapeResult{};
                if (available > 0) {
                    var buf = buffer.buf;
                    const pos = buffer.pos;
                    written = writeEscapeInto(buf[pos..], value);
                }

                var into = larger;
                var buf_start: usize = 0;
                if (written.complete_escape) |b| {
                    larger[0] = b;
                    buf_start = 1;
                    into = larger[1..];
                }
                written = writeEscapeInto(into, value[written.val_pos..]);

                buffer.buf = larger;
                buffer.pos = written.buf_pos + buf_start;
            },
            .none => return error.NoSpaceLeft,
        }
    }

    const WriteEscapeResult = struct {
        val_pos: usize = 0,
        buf_pos: usize = 0,
        complete_escape: ?u8 = null,
    };

    fn writeEscapeInto(buf: []u8, value: []const u8) WriteEscapeResult {
        var buf_pos: usize = 0;
        var val_pos: usize = 0;
        while (buf_pos < buf.len and val_pos < value.len) {
            switch (value[val_pos]) {
                '\n' => {
                    buf[buf_pos] = '\\';
                    buf_pos += 1;
                    if (buf_pos == buf.len) {
                        return .{ .val_pos = val_pos + 1, .buf_pos = buf_pos, .complete_escape = 'n' };
                    }
                    buf[buf_pos] = 'n';
                    buf_pos += 1;
                },
                '"' => {
                    buf[buf_pos] = '\\';
                    buf_pos += 1;
                    if (buf_pos == buf.len) {
                        return .{ .val_pos = val_pos + 1, .buf_pos = buf_pos, .complete_escape = '"' };
                    }
                    buf[buf_pos] = '"';
                    buf_pos += 1;
                },
                else => |b| {
                    buf[buf_pos] = b;
                    buf_pos += 1;
                },
            }
            val_pos += 1;
        }

        return .{ .val_pos = val_pos, .buf_pos = buf_pos };
    }

    fn writeKeyValue(self: *LogFmt, key: []const u8, value: []const u8) void {
        // +1 for the equal sign
        // +1 for the trailing space
        var aw = self.buffer.attributeWriter(2 + key.len + value.len, true) orelse return;
        aw.writeAllB(key, '=');
        aw.writeAllB(value, ' ');
        aw.done();
    }

    const EscapeAnalysis = struct {
        count: usize,
        needed: bool,
    };

    fn escapeAnalysis(value: []const u8) EscapeAnalysis {
        var needed = false;
        var count: usize = 0;
        for (value) |b| {
            if (b == '\n' or b == '"') {
                count += 1;
            } else if (b == ' ' or b == '=') {
                needed = true;
            }
        }

        return .{
            .count = count,
            .needed = needed or count > 0,
        };
    }

    pub const FmtWriter = struct {
        logfmt: *LogFmt,

        pub const Error = anyerror;

        pub fn writeAll(self: FmtWriter, data: []const u8) !void {
            const ea = escapeAnalysis(data);
            if (ea.needed == false) {
                return self.logfmt.buffer.writeAll(data);
            } else {
                return self.logfmt.writeEscapeValue(data, ea.count);
            }
        }

        pub fn writeByteNTimes(self: FmtWriter, b: u8, n: usize) !void {
            return self.logfmt.buffer.writeByteNTimes(b, n);
        }

        pub fn writeBytesNTimes(self: FmtWriter, data: []const u8, n: usize) !void {
            return self.logfmt.buffer.writeBytesNTimes(data, n);
        }
    };
};

test "logfmt: static buffer" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .large_buffer_count = 0, .buffer_size = 25, .encoding = .logfmt });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        // data fits
        logfmt.string("a-key", "a-value");
        try expectLog(&logfmt, "a-key=a-value");
    }

    {
        // data fits with two pairs
        logfmt.string("a-key", "a-val");
        logfmt.string("b-key", "b-val1");
        try expectLog(&logfmt, "a-key=a-val b-key=b-val1");
    }

    {
        // only one pair fits (value too long)
        logfmt.string("a-key", "a-val");
        logfmt.string("b-key", "b-val12");
        try expectLog(&logfmt, "a-key=a-val");
    }

    {
        // only one pair fits (key too long)
        logfmt.string("a-key", "a-val");
        logfmt.string("b-key9", "b-val1");
        try expectLog(&logfmt, "a-key=a-val");
    }
}

test "logfmt: large buffer" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .large_buffer_count = 1, .large_buffer_size = 25, .buffer_size = 25, .encoding = .logfmt });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        logfmt.string("a-key", "a-value");
        try expectLog(&logfmt, "a-key=a-value");
    }

    {
        logfmt.string("a-key", "a-value");
        logfmt.string("b-key", "b-value");
        try expectLog(&logfmt, "a-key=a-value b-key=b-value");
    }

    {
        logfmt.string("a-key", "a-value");
        logfmt.string("larger_key", "b-value");
        logfmt.string("c-key", "c-v");
        try expectLog(&logfmt, "a-key=a-value larger_key=b-value c-key=c-v");
    }

    {
        logfmt.string("a-key", "a-value");
        logfmt.string("b-key", "b-value");
        logfmt.string("c-key", "c-value");
        try expectLog(&logfmt, "a-key=a-value b-key=b-value c-key=c-value");
    }

    {
        // doesn't fit
        logfmt.string("a-key", "a-value");
        logfmt.string("b-key", "b-value");
        logfmt.string("c-key", "c-value");
        logfmt.string("d-key", "d-value");
        try expectLog(&logfmt, "a-key=a-value b-key=b-value c-key=c-value");
    }
}

test "logfmt: buffer fuzz" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .large_buffer_count = 1, .large_buffer_size = 25, .buffer_size = 10, .encoding = .logfmt });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";

    // Out max log length is 35 (10 in our static, 25 in our largr buffer)

    {
        // We should be able to write keys from length 1-32
        // 32 + "=v " (note the space) is 35, our max
        inline for (1..32) |i| {
            logfmt.string(data[0..i], "v");
            try expectLog(&logfmt, data[0..i] ++ "=v");
        }

        // a key of 33 is too long, it makes our total key+value == 36
        logfmt.string(data[0..33], "v");
        try expectLog(&logfmt, null);
    }

    {
        // long values
        // We should be able to write values from length 1-32
        // "k=" + 32 + " " (note the space) is 35, our max
        inline for (1..32) |i| {
            logfmt.string("k", data[0..i]);
            try expectLog(&logfmt, "k=" ++ data[0..i]);
        }

        // a value of 33 is too long, it makes our total key+value == 36
        logfmt.string("k", data[0..33]);
        try expectLog(&logfmt, null);
    }
}

test "logfmt: string" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .large_buffer_count = 0, .buffer_size = 100, .encoding = .logfmt });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        logfmt.string("key", "value");
        logfmt.string("other", "rehto");
        try expectLog(&logfmt, "key=value other=rehto");
    }

    {
        // string requiring encoding
        logfmt.string("key", "the val\"ue");
        try expectLog(&logfmt, "key=\"the val\\\"ue\"");
    }

    {
        // string requiring encoding 2
        logfmt.string("key", "a = b");
        try expectLog(&logfmt, "key=\"a = b\"");
    }

    {
        // null string
        logfmt.string("key", null);
        try expectLog(&logfmt, "key=null");
    }
}

test "logfmt: escape fuzz" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .large_buffer_count = 1, .large_buffer_size = 10, .buffer_size = 20, .encoding = .logfmt });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";

    inline for (0..13) |i| {
        logfmt.string(data[0..i], "\"a\" != \"b\"");
        try expectLog(&logfmt, data[0..i] ++ "=\"\\\"a\\\" != \\\"b\\\"\"");
    }

    logfmt.string(data[0..14], "\"a\" != \"b\"");
    try expectLog(&logfmt, null);
}

test "logfmt: stringZ" {
    const p = try Pool.init(t.allocator, .{
        .pool_size = 1,
        .encoding = .logfmt,
        .large_buffer_count = 0,
        .buffer_size = 100,
    });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        // normal strings
        logfmt.stringZ("key", "value");
        logfmt.stringZ("other", "rehto");
        try expectLog(&logfmt, "key=value other=rehto");
    }

    {
        // string requiring encoding
        logfmt.stringZ("key", "the val\"ue");
        try expectLog(&logfmt, "key=\"the val\\\"ue\"");
    }

    {
        // null string
        logfmt.stringZ("key", @as(?[*:0]const u8, null));
        try expectLog(&logfmt, "key=null");
    }
}

test "logfmt: binary" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 1, .large_buffer_size = 20, .buffer_size = 10 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        logfmt.binary("key", &[_]u8{ 9, 200, 33, 0 });
        try expectLog(&logfmt, "key=CcghAA");
    }

    {
        logfmt.binary("key", @as(?[]const u8, null));
        try expectLog(&logfmt, "key=null");
    }

    var buf: [50]u8 = undefined;
    const data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 };
    for (1..21) |i| {
        const real = b64.encode(&buf, data[0..i]);
        logfmt.binary("k", data[0..i]);
        try expectFmt(&logfmt, "k={s}", .{real});
    }

    logfmt.binary("k", data[0..22]);
    try expectLog(&logfmt, null);
}

test "logfmt: int" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 1, .large_buffer_size = 15, .buffer_size = 10 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    logfmt.int("key", 0);
    try expectLog(&logfmt, "key=0");

    logfmt.int("key", -1);
    try expectLog(&logfmt, "key=-1");

    logfmt.int("key", 1234567890);
    try expectLog(&logfmt, "key=1234567890");

    logfmt.int("key", -1234567890);
    try expectLog(&logfmt, "key=-1234567890");

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";
    inline for (0..18) |i| {
        logfmt.int(data[0..i], 12345);
        try expectLog(&logfmt, data[0..i] ++ "=12345");
    }
    logfmt.int(data[0..19], 12345);
    try expectLog(&logfmt, null);

    logfmt.int(data[0..18], -12345);
    try expectLog(&logfmt, null);

    logfmt.int(data[0..18], -1234);
    try expectLog(&logfmt, data[0..18] ++ "=-1234");

    logfmt.int(data[0..18], null);
    try expectLog(&logfmt, data[0..18] ++ "=null");
}

test "logfmt: int special values" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    // max-ish
    logfmt.int("n", 123456789123456798123456789123456789123456798123456789);
    try expectLog(&logfmt, "n=123456789123456798123456789123456789123456798123456789");

    // min-ish
    logfmt.int("n", -123456789123456798123456789123456789123456798123456789);
    try expectLog(&logfmt, "n=-123456789123456798123456789123456789123456798123456789");

    logfmt.int("n", @as(?u32, null));
    try expectLog(&logfmt, "n=null");
}

test "logfmt: bool null/true/false" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 0, .buffer_size = 20 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    logfmt.boolean("tea", true);
    try expectLog(&logfmt, "tea=Y");

    logfmt.boolean("coffee", false);
    try expectLog(&logfmt, "coffee=N");

    logfmt.boolean("other", @as(?bool, null));
    try expectLog(&logfmt, "other=null");
}

test "logfmt: float" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 1, .large_buffer_size = 15, .buffer_size = 10 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    logfmt.float("key", 0);
    try expectLog(&logfmt, "key=0");

    logfmt.float("key", -1);
    try expectLog(&logfmt, "key=-1");

    logfmt.float("key", 12345.67891);
    try expectLog(&logfmt, "key=12345.67891");

    logfmt.float("key", -1.234567891);
    try expectLog(&logfmt, "key=-1.234567891");

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";
    inline for (0..17) |i| {
        logfmt.float(data[0..i], 1.2345);
        try expectLog(&logfmt, data[0..i] ++ "=1.2345");
    }
    logfmt.float(data[0..18], 1.2345);
    try expectLog(&logfmt, null);

    logfmt.float(data[0..18], -1.234);
    try expectLog(&logfmt, null);

    logfmt.float(data[0..17], -123.4);
    try expectLog(&logfmt, data[0..17] ++ "=-123.4");

    logfmt.float(data[0..17], null);
    try expectLog(&logfmt, data[0..17] ++ "=null");
}

test "logfmt: error" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        // normal strings
        logfmt.errK("err", error.FileNotFound);
        try expectLog(&logfmt, "err=FileNotFound");
    }

    {
        logfmt.err(error.FileNotFound);
        try expectLog(&logfmt, "@err=FileNotFound");
    }
}

test "logfmt: ctx" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    logfmt.ctx("test.logfmt.ctx");
    try expectLog(&logfmt, "@ctx=test.logfmt.ctx");
}

test "logfmt: src" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        // normal strings
        const src = @src();
        logfmt.src(src);
        try expectFmt(&logfmt, "@src.file=logfmt.zig @src.fn=\"test.logfmt: src\" @src.line={d}", .{src.line});
    }
}

test "logfmt: fmt" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .logfmt, .large_buffer_count = 1, .large_buffer_size = 20, .buffer_size = 10 });
    defer p.deinit();

    var logfmt = try LogFmt.init(t.allocator, p);
    defer logfmt.deinit(t.allocator);

    {
        // normal strings
        logfmt.fmt("key", "over:{d}", .{9000});
        try expectLog(&logfmt, "key=\"over:9000\"");
    }

    {
        // with escape
        logfmt.fmt("key", "over={d}\n!!", .{9001});
        try expectLog(&logfmt, "key=\"over=9001\\n!!\"");
    }

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";
    inline for (0..20) |i| {
        logfmt.fmt("key", "> {s} <", .{data[0..i]});
        try expectLog(&logfmt, "key=\"> " ++ data[0..i] ++ " <\"");
    }

    logfmt.fmt("key", "> {s} <", .{data[0..21]});
    try expectLog(&logfmt, null);
}

fn expectLog(lf: *LogFmt, comptime expected: ?[]const u8) !void {
    defer lf.reset();

    var out = std.ArrayList(u8).init(t.allocator);
    try out.ensureTotalCapacity(100);
    defer out.deinit();

    try lf.logTo(out.writer());
    if (expected) |e| {
        try t.expectString("@ts=9999999999999 " ++ e ++ "\n", out.items);
    } else {
        try t.expectEqual(0, out.items.len);
    }
}

fn expectFmt(lf: *LogFmt, comptime fmt: []const u8, args: anytype) !void {
    defer lf.reset();

    var out = std.ArrayList(u8).init(t.allocator);
    try out.ensureTotalCapacity(100);
    defer out.deinit();

    try lf.logTo(out.writer());

    var buf: [200]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "@ts=9999999999999 " ++ fmt ++ "\n", args);
    try t.expectString(expected, out.items);
}
