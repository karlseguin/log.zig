const std = @import("std");
const logz = @import("logz.zig");

const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;
const Buffer = @import("buffer.zig").Buffer;

const File = std.fs.File;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad.Encoder;

const META_LEN = "{\"@ts\":9999999999999,\"@l\":\"ERROR\",".len;

const t = @import("t.zig");
const timestamp = if (t.is_test) t.timestamp else std.time.milliTimestamp;

pub const Json = struct {
    out: File,

    lvl: logz.Level,

    // space for a configured prefix + the @ts=$time and @l=$level meta fields
    meta: []u8,

    buffer: Buffer,

    multiuse_length: ?usize,

    mutex: *Mutex,

    pub fn init(allocator: Allocator, pool: *Pool) !Json {
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

    pub fn deinit(self: *Json, allocator: Allocator) void {
        allocator.free(self.meta);
        self.buffer.deinit();
    }

    pub fn multiuse(self: *Json) void {
        self.multiuse_length = self.buffer.pos;
    }

    pub fn reset(self: *Json) void {
        self.lvl = .None;
        self.multiuse_length = null;
        self.buffer.reset(0);
    }

    pub fn reuse(self: *Json) void {
        self.lvl = .None;
        self.buffer.reset(self.multiuse_length orelse 0);
    }

    pub fn level(self: *Json, lvl: logz.Level) void {
        self.lvl = lvl;
    }

    pub fn ctx(self: *Json, value: []const u8) void {
        self.string("@ctx", value);
    }

    pub fn src(self: *Json, value: std.builtin.SourceLocation) void {
        self.writeObject("@src", .{ .file = value.file, .@"fn" = value.fn_name, .line = value.line });
    }

    pub fn string(self: *Json, key: []const u8, nvalue: ?[]const u8) void {
        const value = nvalue orelse {
            self.writeNull(key);
            return;
        };

        const rewind = self.startKeyValue(key, value.len) orelse return;
        var buffer = &self.buffer;
        std.json.encodeJsonString(value, .{}, buffer) catch {
            buffer.rollback(rewind);
            return;
        };
        buffer.writeByte(',') catch buffer.rollback(rewind);
    }

    pub fn fmt(self: *Json, key: []const u8, comptime format: []const u8, values: anytype) void {
        const rewind = self.startKeyValue(key, 2) orelse return;

        var buffer = &self.buffer;

        buffer.writeByte('"') catch {
            buffer.rollback(rewind);
            return;
        };

        std.fmt.format(FmtWriter{ .buffer = &self.buffer }, format, values) catch {
            buffer.rollback(rewind);
            return;
        };

        buffer.writeAll("\",") catch {
            buffer.rollback(rewind);
            return;
        };
    }

    pub fn stringZ(self: *Json, key: []const u8, nvalue: ?[*:0]const u8) void {
        if (nvalue == null) {
            self.writeNull(key);
            return;
        }
        self.string(key, std.mem.span(nvalue));
    }

    // cases where the caller is sure value does not need to be encoded
    pub fn stringSafe(self: *Json, key: []const u8, nvalue: ?[]const u8) void {
        const value = nvalue orelse {
            self.writeNull(key);
            return;
        };

        // + 2 for the quotes around the key
        // + 2 for the quotes around the value
        // + 1 fo rthe comma
        // + 1 for the trailing comma
        var aw = self.buffer.attributeWriter(6 + key.len + value.len, true) orelse return;
        aw.writeByte('"');
        aw.writeAllAll(key, "\":\"");
        aw.writeAllAll(value, "\",");
        aw.done();
    }

    // cases where the caller is sure value does not need to be encoded
    pub fn stringSafeZ(self: *Json, key: []const u8, value: ?[*:0]const u8) void {
        if (value) |v| {
            self.stringSafe(key, std.mem.span(v));
        } else {
            self.writeNull(key);
        }
    }

    pub fn int(self: *Json, key: []const u8, value: anytype) void {
        const f = switch (@typeInfo(@TypeOf(value))) {
            .Optional => blk: {
                if (value) |v| {
                    break :blk v;
                }
                self.writeNull(key);
                return;
            },
            .Null => {
                self.writeNull(key);
                return;
            },
            else => value,
        };

        const rewind = self.startKeyValue(key, 0) orelse return;
        var buffer = &self.buffer;
        std.fmt.formatType(f, "d", .{}, buffer.writer(), 0) catch {
            self.buffer.rollback(rewind);
            return;
        };
        buffer.writeByte(',') catch self.buffer.rollback(rewind);
    }

    pub fn float(self: *Json, key: []const u8, value: anytype) void {
        const f = switch (@typeInfo(@TypeOf(value))) {
            .Optional => blk: {
                if (value) |v| {
                    break :blk v;
                }
                self.writeNull(key);
                return;
            },
            .Null => {
                self.writeNull(key);
                return;
            },
            else => value,
        };

        const rewind = self.startKeyValue(key, 0) orelse return;
        var buffer = &self.buffer;
        std.fmt.formatType(f, "d", .{}, buffer.writer(), 0) catch {
            self.buffer.rollback(rewind);
            return;
        };
        buffer.writeByte(',') catch self.buffer.rollback(rewind);
    }

    pub fn boolean(self: *Json, key: []const u8, value: anytype) void {
        const b = switch (@typeInfo(@TypeOf(value))) {
            .Optional => blk: {
                if (value) |v| {
                    break :blk v;
                }
                self.writeNull(key);
                return;
            },
            .Null => {
                self.writeNull(key);
                return;
            },
            else => value,
        };

        const l: usize = if (b) 4 else 5;
        // + 2 for the quotes around the key
        // + 1 for the colon
        // + 1 for the trailing comma
        var aw = self.buffer.attributeWriter(4 + key.len + l, true) orelse return;
        aw.writeByte('"');
        if (b) {
            aw.writeAllAll(key, "\":true,");
        } else {
            aw.writeAllAll(key, "\":false,");
        }
        aw.done();
    }

    pub fn binary(self: *Json, key: []const u8, nvalue: ?[]const u8) void {
        const value = nvalue orelse {
            self.writeNull(key);
            return;
        };

        // + 4 for the quotes around the key and value
        // + 1 for the colon
        // + 1 for the trailing comma
        var aw = self.buffer.attributeWriter(6 + key.len + b64.calcSize(value.len), true) orelse return;
        aw.writeByte('"');
        aw.writeAllAll(key, "\":\"");

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
        aw.writeAll("\",");
        aw.done();
    }

    pub fn err(self: *Json, value: anyerror) void {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .Optional => {
                if (value) |v| {
                    self.string("@err", @errorName(v));
                } else {
                    self.writeNull("@err");
                }
            },
            else => self.string("@err", @errorName(value)),
        }
    }

    pub fn errK(self: *Json, key: []const u8, value: anyerror) void {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .Optional => {
                if (value) |v| {
                    self.string(key, @errorName(v));
                } else {
                    self.writeNull(key);
                }
            },
            else => self.string(key, @errorName(value)),
        }
    }

    pub fn tryLog(self: *Json) !void {
        try self.logTo(self.out);
    }

    pub fn log(self: *Json) void {
        self.logTo(self.out) catch |e| {
            const msg = "logz: Failed to write log. Log will be dropped. Error was: {}";
            std.log.err(msg, .{e});
        };
    }

    pub fn logTo(self: *Json, out: anytype) !void {
        const buffer = &self.buffer;
        var pos = buffer.pos;

        if (pos == 0) {
            // nothing was logged (or nothing fit in the buffers)
            return;
        }

        const meta = self.meta;
        const meta_len = blk: {
            // append timestamp to our meta
            const prefix_len = meta.len - META_LEN;
            const meta_buf = meta[prefix_len..];

            if (prefix_len == 0) {
                @memcpy(meta_buf[0..7], "{\"@ts\":");
            } else {
                // whitespce in json is ignored, and putting it in keeps all our offsets the same
                @memcpy(meta_buf[0..7], " \"@ts\":");
            }
            _ = std.fmt.formatIntBuf(meta_buf[7..], timestamp(), 10, .lower, .{});

            switch (self.lvl) {
                .Debug => {
                    @memcpy(meta_buf[20..], ",\"@l\":\"DEBUG\",");
                    break :blk meta.len;
                },
                .Info => {
                    @memcpy(meta_buf[20..33], ",\"@l\":\"INFO\",");
                    break :blk meta.len - 1;
                },
                .Warn => {
                    @memcpy(meta_buf[20..33], ",\"@l\":\"WARN\",");
                    break :blk meta.len - 1;
                },
                .Error => {
                    @memcpy(meta_buf[20..], ",\"@l\":\"ERROR\",");
                    break :blk meta.len;
                },
                .Fatal => {
                    @memcpy(meta_buf[20..], ",\"@l\":\"FATAL\",");
                    break :blk meta.len;
                },
                else => {
                    meta_buf[20] = ',';
                    break :blk meta.len - 13;
                },
            }
        };

        var buf = buffer.buf;
        // replace the last comma
        buf[pos - 1] = '}';

        const static = buffer.static;

        var flush_newline = false;
        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        } else {
            // Unlucky, our buffer is full, we don't have space for the final newline
            // We'll solve this by issuing a final out.writeAll("\n");
            flush_newline = true;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try out.writeAll(meta[0..meta_len]);
        if (buf.ptr != static.ptr) {
            // if we had to get a larger buffer, than static should be filled
            try out.writeAll(static);
        }

        // we should always write a trailing space, the last of which, we can
        // now replace with our closing bracket
        try out.writeAll(buf[0..pos]);
        if (flush_newline) {
            try out.writeAll("\n");
        }
    }

    fn startKeyValue(self: *Json, key: []const u8, min_value_len: usize) ?Buffer.RewindState {
        var buffer = &self.buffer;
        const rewind = buffer.begin();
        switch (buffer.sizeCheck(key.len + 4 + min_value_len)) {
            .none => return null,
            .buf => {
                // optimize this common case
                buffer.writeByteBuf('"');
                buffer.writeAllBuf(key);
                buffer.writeAllBuf("\":");
            },
            .acquire_large => {
                buffer.writeByte('"') catch return null;
                buffer.writeAll(key) catch {
                    buffer.rollback(rewind);
                    return null;
                };
                buffer.writeAll("\":") catch {
                    buffer.rollback(rewind);
                    return null;
                };
            },
        }

        return rewind;
    }

    fn writeNull(self: *Json, key: []const u8) void {
        // + 2 for the quotes around the key
        // + 1 for the colon
        // + 4 for null
        // + 1 for the trailing comma
        var aw = self.buffer.attributeWriter(8 + key.len, true) orelse return;
        aw.writeByte('"');
        aw.writeAllAll(key, "\":null,");
        aw.done();
    }

    fn writeObject(self: *Json, key: []const u8, value: anytype) void {
        const rewind = self.startKeyValue(key, 2) orelse return;
        var buffer = &self.buffer;
        std.json.stringify(value, .{}, Writer{ .buffer = buffer }) catch {
            buffer.rollback(rewind);
            return;
        };
        buffer.writeByte(',') catch buffer.rollback(rewind);
    }

    pub const FmtWriter = struct {
        buffer: *Buffer,

        pub const Error = anyerror;

        pub fn writeAll(self: FmtWriter, data: []const u8) !void {
            return std.json.encodeJsonStringChars(data, .{}, self.buffer);
        }

        pub fn writeByteNTimes(self: FmtWriter, b: u8, n: usize) !void {
            return self.buffer.writeByteNTimes(b, n);
        }

        pub fn writeBytesNTimes(self: FmtWriter, data: []const u8, n: usize) !void {
            return self.buffer.writeBytesNTimes(data, n);
        }
    };

    pub const Writer = struct {
        buffer: *Buffer,

        pub const Error = anyerror;

        pub fn writeByte(self: Writer, b: u8) !void {
            return self.buffer.writeByte(b);
        }

        pub fn writeByteNTimes(self: Writer, b: u8, n: usize) !void {
            return self.buffer.writeByteNTimes(b, n);
        }

        pub fn writeBytesNTimes(self: Writer, data: []const u8, n: usize) !void {
            return self.buffer.writeBytesNTimes(data, n);
        }

        pub fn writeAll(self: Writer, value: []const u8) !void {
            return self.buffer.writeAll(value);
        }

        pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
            return std.fmt.format(self, format, args);
        }
    };
};

test "json: static buffer" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 35 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    // data fits
    json.string("key", "a-value");
    try expectLog(&json, "\"key\":\"a-value\"");

    // data fits with two pairs
    json.string("a-key", "a-val");
    json.string("b-key", "b-val1");
    try expectLog(&json, "\"a-key\":\"a-val\",\"b-key\":\"b-val1\"");

    // only one pair fits
    json.string("a-key", "a-val");
    json.string("b-key", "b-val123aa");
    try expectLog(&json, "\"a-key\":\"a-val\"");

    // only one pair fits (key too long)
    json.string("a-key", "a-val");
    json.string("b-key933", "b-val1");
    try expectLog(&json, "\"a-key\":\"a-val\"");

    json.string("key", null);
    try expectLog(&json, "\"key\":null");
}

test "json: large buffer" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 40, .buffer_size = 20 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    {
        json.string("a-key", "a-value");
        try expectLog(&json, "\"a-key\":\"a-value\"");
    }

    {
        json.string("a-key", "a-value");
        json.string("b-key", "b-value");
        try expectLog(&json, "\"a-key\":\"a-value\",\"b-key\":\"b-value\"");
    }

    {
        json.string("a-key", "a-value");
        json.string("larger_key", "b-value");
        json.string("c-key", "c-v");
        try expectLog(&json, "\"a-key\":\"a-value\",\"larger_key\":\"b-value\",\"c-key\":\"c-v\"");
    }

    {
        json.string("a-key", "a-value");
        json.string("b-key", "b-value");
        json.string("c-key", "c-value");
        try expectLog(&json, "\"a-key\":\"a-value\",\"b-key\":\"b-value\",\"c-key\":\"c-value\"");
    }

    {
        // doesn't fit
        json.string("a-key", "a-value");
        json.string("b-key", "b-value");
        json.string("c-key", "c-value");
        json.string("d-key", "d-value");
        try expectLog(&json, "\"a-key\":\"a-value\",\"b-key\":\"b-value\",\"c-key\":\"c-value\"");
    }
}

test "json: buffer fuzz" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 25, .buffer_size = 10 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";

    {
        inline for (1..28) |i| {
            json.string(data[0..i], "v");
            try expectLog(&json, "\"" ++ data[0..i] ++ "\":\"v\"");
        }

        // a key of 33 is too long, it makes our total key+value == 36
        json.string(data[0..29], "v");
        try expectLog(&json, null);
    }

    {
        // long values
        // We should be able to write values from length 1-32
        // "k=" + 32 + " " (note the space) is 35, our max
        inline for (1..28) |i| {
            json.string("k", data[0..i]);
            try expectLog(&json, "\"k\":\"" ++ data[0..i] ++ "\"");
        }

        // a value of 33 is too long, it makes our total key+value == 36
        json.string("k", data[0..29]);
        try expectLog(&json, null);
    }
}

test "json: stringZ" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    {
        // normal strings
        json.stringZ("key", "value");
        json.stringZ("other", "rehto");
        try expectLog(&json, "\"key\":\"value\",\"other\":\"rehto\"");
    }

    {
        // null string
        json.stringZ("key", @as(?[*:0]const u8, null));
        try expectLog(&json, "\"key\":null");
    }
}

test "json: binary" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 20, .buffer_size = 10 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    {
        json.binary("key", &[_]u8{ 9, 200, 33, 0 });
        try expectLog(&json, "\"key\":\"CcghAA\"");
    }

    {
        json.binary("key", @as(?[]const u8, null));
        try expectLog(&json, "\"key\":null");
    }

    var buf: [50]u8 = undefined;
    const data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 };
    for (1..17) |i| {
        const real = b64.encode(&buf, data[0..i]);
        json.binary("k", data[0..i]);
        try expectFmt(&json, "\"k\":\"{s}\"", .{real});
    }

    json.binary("k", data[0..18]);
    try expectLog(&json, null);
}

test "json: int" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 15, .buffer_size = 10 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    json.int("key", 0);
    try expectLog(&json, "\"key\":0");

    json.int("key", -1);
    try expectLog(&json, "\"key\":-1");

    json.int("key", 1234567890);
    try expectLog(&json, "\"key\":1234567890");

    json.int("key", -1234567890);
    try expectLog(&json, "\"key\":-1234567890");

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";
    inline for (1..16) |i| {
        json.int(data[0..i], 12345);
        try expectLog(&json, "\"" ++ data[0..i] ++ "\":12345");
    }
    json.int(data[0..17], 12345);
    try expectLog(&json, null);

    json.int(data[0..16], -12345);
    try expectLog(&json, null);

    json.int(data[0..16], -1234);
    try expectLog(&json, "\"" ++ data[0..16] ++ "\":-1234");

    json.int(data[0..16], null);
    try expectLog(&json, "\"" ++ data[0..16] ++ "\":null");
}

test "json: int special values" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    // max-ish
    json.int("n", 123456789123456798123456789123456789123456798123456789);
    try expectLog(&json, "\"n\":123456789123456798123456789123456789123456798123456789");

    // min-ish
    json.int("n", -123456789123456798123456789123456789123456798123456789);
    try expectLog(&json, "\"n\":-123456789123456798123456789123456789123456798123456789");

    json.int("n", @as(?u32, null));
    try expectLog(&json, "\"n\":null");
}

test "json: bool null/true/false" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 20 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    json.boolean("tea", true);
    try expectLog(&json, "\"tea\":true");

    json.boolean("coffee", false);
    try expectLog(&json, "\"coffee\":false");

    json.boolean("other", @as(?bool, null));
    try expectLog(&json, "\"other\":null");
}

test "json: float" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 15, .buffer_size = 10 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    json.float("key", 0);
    try expectLog(&json, "\"key\":0");

    json.float("key", -1);
    try expectLog(&json, "\"key\":-1");

    json.float("key", 12345.67891);
    try expectLog(&json, "\"key\":12345.67891");

    json.float("key", -1.234567891);
    try expectLog(&json, "\"key\":-1.234567891");

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";
    inline for (1..15) |i| {
        json.float(data[0..i], 1.2345);
        try expectLog(&json, "\"" ++ data[0..i] ++ "\":1.2345");
    }
    json.float(data[0..16], 1.2345);
    try expectLog(&json, null);

    json.float(data[0..16], -1.234);
    try expectLog(&json, null);

    json.float(data[0..15], -123.4);
    try expectLog(&json, "\"" ++ data[0..15] ++ "\":-123.4");

    json.float(data[0..15], null);
    try expectLog(&json, "\"" ++ data[0..15] ++ "\":null");
}

test "json: error" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    {
        // normal strings
        json.errK("err", error.FileNotFound);
        try expectLog(&json, "\"err\":\"FileNotFound\"");
    }

    {
        json.err(error.FileNotFound);
        try expectLog(&json, "\"@err\":\"FileNotFound\"");
    }
}

test "json: ctx" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    json.ctx("test.json.ctx");
    try expectLog(&json, "\"@ctx\":\"test.json.ctx\"");
}

test "json: src" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 0, .buffer_size = 100 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    const src = @src();
    json.src(src);
    try expectFmt(&json, "\"@src\":{{\"file\":\"src/json.zig\",\"fn\":\"test.json: src\",\"line\":{d}}}", .{src.line});
}

test "json: src larger" {
    // more tests for this since it's the only code that calls writeObjet for now
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 70, .buffer_size = 30 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    const src = @src();
    json.src(src);
    try expectFmt(&json, "\"@src\":{{\"file\":\"src/json.zig\",\"fn\":\"test.json: src larger\",\"line\":{d}}}", .{src.line});
}

test "json: src doesn't fit" {
    // more tests for this since it's the only code that calls writeObjet for now
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 30, .buffer_size = 10 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    json.src(@src());
    try expectLog(&json, null);
}

test "json: fmt" {
    const p = try Pool.init(t.allocator, .{ .pool_size = 1, .encoding = .json, .large_buffer_count = 1, .large_buffer_size = 20, .buffer_size = 10 });
    defer p.deinit();

    var json = try Json.init(t.allocator, p);
    defer json.deinit(t.allocator);

    {
        // normal strings
        json.fmt("key", "over:{d}", .{9000});
        try expectLog(&json, "\"key\":\"over:9000\"");
    }

    {
        // with escape
        json.fmt("key", "over={d}\n!!", .{9001});
        try expectLog(&json, "\"key\":\"over=9001\\n!!\"");
    }

    const data = "1234567890ABCDEFGHIJKLMNOPQRSTUFWXYZ";
    inline for (0..18) |i| {
        json.fmt("key", "> {s} <", .{data[0..i]});
        try expectLog(&json, "\"key\":\"> " ++ data[0..i] ++ " <\"");
    }

    json.fmt("key", "> {s} <", .{data[0..19]});
    try expectLog(&json, null);
}

fn expectLog(json: *Json, comptime expected: ?[]const u8) !void {
    defer json.reset();

    var out = std.ArrayList(u8).init(t.allocator);
    try out.ensureTotalCapacity(100);
    defer out.deinit();

    try json.logTo(out.writer());
    if (expected) |e| {
        try t.expectString("{\"@ts\":9999999999999," ++ e ++ "}\n", out.items);
    } else {
        try t.expectEqual(0, out.items.len);
    }
}

fn expectFmt(json: *Json, comptime fmt: []const u8, args: anytype) !void {
    defer json.reset();

    var out = std.ArrayList(u8).init(t.allocator);
    try out.ensureTotalCapacity(100);
    defer out.deinit();

    try json.logTo(out.writer());

    var buf: [200]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{{\"@ts\":9999999999999," ++ fmt ++ "}}\n", args);
    try t.expectString(expected, out.items);
}
