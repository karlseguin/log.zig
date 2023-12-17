const std = @import("std");

const t = @import("t.zig");
const logz = @import("logz.zig");
const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;

const mem = std.mem;
const File = std.fs.File;
const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad.Encoder;

const timestamp = if (t.is_test) t.timestamp else std.time.milliTimestamp;

pub const Kv = struct {
	buf: []u8,
	pos: usize,
	out: File,
	lvl: logz.Level,
	prefix_length: usize,
	multiuse_length: ?usize,

	pub fn init(allocator: Allocator, config: Config) !Kv {
		const buf = try allocator.alloc(u8, config.max_size);

		var prefix_length: usize = 0;
		if (config.prefix) |prefix| {
			prefix_length = prefix.len;
			for (prefix, 0..) |b, i| {
				buf[i] = b;
			}
			if (buf[prefix_length] != ' ') {
				buf[prefix_length] = ' ';
				prefix_length += 1;
			}
		}

		return .{
			.buf = buf,
			.lvl = .None,
			.multiuse_length = null,
			.prefix_length = prefix_length,
			.pos = prefix_length,
			.out = switch (config.output) {
				.stdout => std.io.getStdOut(),
				.stderr => std.io.getStdErr(),
			}
		};
	}

	pub fn deinit(self: *Kv, allocator: Allocator) void {
		allocator.free(self.buf);
	}

	pub fn multiuse(self: *Kv) void {
		self.multiuse_length = self.pos;
	}

	pub fn reset(self: *Kv) void {
		self.lvl = .None;
		self.multiuse_length = null;
		self.pos = self.prefix_length;
	}

	pub fn reuse(self: *Kv) void {
		self.lvl = .None;
		self.pos = if (self.multiuse_length) |l| l else 0;
	}

	pub fn level(self: *Kv, lvl: logz.Level) void {
		self.lvl = lvl;
	}

	pub fn ctx(self: *Kv, value: []const u8) void {
		if (!self.writeKeyForValue("@ctx", value.len)) return;
		const pos = self.pos;
		const end = pos+value.len;
		@memcpy(self.buf[pos..end], value);
		self.pos = end;
	}

	pub fn src(self: *Kv, value: std.builtin.SourceLocation) void {
		self.string("@src.file", value.file);
		self.string("@src.fn", value.fn_name);
		self.int("@src.line", value.line);
	}

	pub fn string(self: *Kv, key: []const u8, nvalue: ?[]const u8) void {
		if (nvalue == null) {
			self.writeNull(key);
			return;
		}

		const value = nvalue.?;
		if (!self.writeKeyForValue(key, value.len)) return;

		var pos = self.pos;

		const buf = self.buf;
		const original_pos = self.pos;

		var needs_escape = false;
		var escape_index: usize = 0;
		for (value, 0..) |b, i| {
			if (b == '=' or b == '"' or b == '\n' or b == ' ') {
				needs_escape = true;
				escape_index = i;
				break;
			}
		}

		if (!needs_escape) {
			const end = pos+value.len;
			@memcpy(self.buf[pos..end], value);
			self.pos = end;
			return;
		}

		buf[pos] = '"';
		pos += 1;

		// we can directly copy up to the first escape sequence
		const unescaped_end = pos + escape_index;
		@memcpy(buf[pos..unescaped_end], value[0..escape_index]);
		pos = unescaped_end;
		self.pos = pos;

		self.writeEscapeValue(value[escape_index..]) catch {
			self.pos = original_pos;
		};

		// this has to be safe, because writeEscapeValue always saves 1 space at the end
		pos = self.pos;
		buf[pos] = '"';
		self.pos = pos + 1;
	}

	pub fn fmt(self: *Kv, key: []const u8, comptime format: []const u8, values: anytype) void {
		// if our write fails, we'll revert back to the initial position
		const initial_pos = self.pos;
		// we don't know the length of the final value, but it'll always be
		// escaped, so we know we need at least 2 extra bytes for the opening and
		// closing quotes
		if (!self.writeKeyForValue(key, 2)) return;

		const buf = self.buf;
		var pos = self.pos;
		buf[pos] = '"';
		self.pos = pos + 1;

		std.fmt.format(FmtWriter{.kv = self}, format, values) catch {
			self.pos = initial_pos;
			return;
		};

		// this has to be safe, because writeEscapeValue always saves 1 space at the end
		pos = self.pos;
		buf[pos] = '"';
		self.pos = pos + 1;
	}

	pub fn stringZ(self: *Kv, key: []const u8, nvalue: ?[*:0]const u8) void {
		if (nvalue == null) {
			self.writeNull(key);
			return;
		}
		self.string(key, std.mem.span(nvalue));
	}

	// cases where the caller is sure value does not need to be encoded
	pub fn stringSafe(self: *Kv, key: []const u8, value: ?[]const u8) void {
		if (value) |v| {
			if (!self.writeKeyForValue(key, v.len)) return;
			const pos = self.pos;
			const end = pos+v.len;
			@memcpy(self.buf[pos..end], v);
			self.pos = end;
		} else {
			self.writeNull(key);
		}
	}

	// cases where the caller is sure value does not need to be encoded
	pub fn stringSafeZ(self: *Kv, key: []const u8, value: ?[*:0]const u8) void {
		if (value) |v| {
			self.stringSafe(key, std.mem.span(v));
		} else {
			self.writeNull(key);
		}
	}

	pub fn int(self: *Kv, key: []const u8, value: anytype) void {
		const T = @TypeOf(value);

		switch (@typeInfo(T)) {
			.Optional => {
				if (value) |v| {
					self.writeInt(key, v);
				} else {
					self.writeNull(key);
				}
			},
			else => self.writeInt(key, value),
		}
	}

	pub fn float(self: *Kv, key: []const u8, value: anytype) void {
		const T = @TypeOf(value);
		switch (@typeInfo(T)) {
			.Optional => {
				if (value) |v| {
					self.writeFloat(key, v);
				} else {
					self.writeNull(key);
				}
			},
			else => self.writeFloat(key, value),
		}
	}

	pub fn boolean(self: *Kv, key: []const u8, value: anytype) void {
		const T = @TypeOf(value);
		switch (@typeInfo(T)) {
			.Optional => {
				if (value) |v| {
					self.writeBool(key, v);
				} else {
					self.writeNull(key);
				}
			},
			else => self.writeBool(key, value),
		}
	}

	pub fn binary(self: *Kv, key: []const u8, value: ?[]const u8) void {
		if (value) |v| {
			const enc_len = b64.calcSize(v.len);
			if (!self.writeKeyForValue(key, enc_len)) return;

			// base64 encoded value never requires escaping, yay.
			const pos = self.pos;
			_ = b64.encode(self.buf[pos..], v);
			self.pos = pos + enc_len;
		} else {
			self.writeNull(key);
		}
	}

	pub fn err(self: *Kv, value: anyerror) void {
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

	pub fn errK(self: *Kv, key: []const u8, value: anyerror) void {
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

	pub fn tryLog(self: *Kv) !void {
		try self.logTo(self.out);
	}

	pub fn log(self: *Kv) void {
		self.logTo(self.out) catch |e| {
			const msg = "logz: Failed to write log. Log will be dropped. Error was: {}";
			std.log.err(msg, .{e});
		};
	}

	pub fn logTo(self: *Kv, out: anytype) !void {
		const pos = self.pos;
		const buf = self.buf;
		const prefix_length = self.prefix_length;

		if (prefix_length > 0) {
			try out.writeAll(buf[0..prefix_length]);
		}

		var meta: [27]u8 = undefined;
		@memcpy(meta[0..4], "@ts=");
		_ = std.fmt.formatIntBuf(meta[4..], timestamp(), 10, .lower, .{});

		switch (self.lvl) {
			.Debug => {
				@memcpy(meta[17..], " @l=DEBUG ");
				try out.writeAll(&meta);
			},
			.Info => {
				@memcpy(meta[17..26], " @l=INFO ");
				try out.writeAll(meta[0..26]);
			},
			.Warn => {
				@memcpy(meta[17..26], " @l=WARN ");
				try out.writeAll(meta[0..26]);
			},
			.Error => {
				@memcpy(meta[17..], " @l=ERROR ");
				try out.writeAll(&meta);
			},
			.Fatal => {
				@memcpy(meta[17..], " @l=FATAL ");
				try out.writeAll(&meta);
			},
			else => {
				meta[17] = ' ';
				try out.writeAll(meta[0..18]);
			},
		}

		if (pos != buf.len) {
			buf[pos] = '\n';
			try out.writeAll(buf[prefix_length..pos+1]);
		} else {
			try out.writeAll(buf[prefix_length..pos]);
			try out.writeAll("\n");
		}
	}

	fn writeInt(self: *Kv, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		if (!self.writeKeyForValue(key, 0)) return;

		std.fmt.formatInt(value, 10, .lower, .{}, self) catch {
			self.pos = rollback_position;
		};
	}

	fn writeFloat(self: *Kv, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		if (!self.writeKeyForValue(key, 0)) return;

		std.fmt.formatFloatDecimal(value, .{}, self) catch {
			self.pos = rollback_position;
		};
	}

	fn writeBool(self: *Kv, key: []const u8, value: anytype) void {
		if (!self.writeKeyForValue(key, 1)) return;

		// writeKeyForValue made sure we have 1 free space
		const pos = self.pos;
		switch (value) {
			true => self.buf[pos] = 'Y',
			false => self.buf[pos] = 'N',
		}

		self.pos = pos + 1;
	}

	fn writeNull(self: *Kv, key: []const u8) void {
		if (!self.writeKeyForValue(key, 4)) return;

		// writeKeyForValue made sure we have 4 free spaces
		const pos = self.pos;
		const buf = self.buf;
		buf[pos] = 'n';
		buf[pos+1] = 'u';
		buf[pos+2] = 'l';
		buf[pos+3] = 'l';
		self.pos = pos + 4;
	}

	fn writeKeyForValue(self: *Kv, key: []const u8, value_len: usize) bool {
		var pos = self.pos;
		const buf = self.buf;

		// +2 because we'll be appending an '='' after the key
		// and because we'll probably be pre-pending a ' '.
		if (!haveSpace(buf.len, pos, key.len+2 + value_len)) {
			return false;
		}

		if (pos > self.prefix_length) {
			buf[pos] = ' ';
			pos += 1;
		}

		const end = pos+key.len;
		@memcpy(buf[pos..end], key);
		pos = end;
		buf[pos] = '=';
		self.pos = pos + 1;
		return true;
	}

	pub fn writeAll(self: *Kv, data: []const u8) !void {
		const pos = self.pos;
		const buf = self.buf;

		if (!haveSpace(buf.len, pos, data.len)) return error.NoSpaceLeft;

		@memcpy(buf[pos..pos+data.len], data);
		self.pos = pos + data.len;
	}

	// formatInt writer interface
	pub fn writeByteNTimes(self: *Kv, b: u8, n: usize) !void {
		const pos = self.pos;
		const buf = self.buf;
		if (!haveSpace(buf.len, pos, n)) return error.NoSpaceLeft;

		for (0..n) |i| {
			buf[pos+i] = b;
		}
		self.pos = pos + n;
	}

	fn writeEscapeValue(self: *Kv, value: []const u8) !void {
		const buf = self.buf;
		var pos = self.pos;

		// At a minimum, we'll need 1 quotes to end our value
		const needed = value.len + 1;
		const left = buf.len - pos;
		if (needed > left) {
			return error.NoSpaceLeft;
		}
		var spare = left - needed;

		for (value) |b| {
			switch (b) {
				'\n' => {
					if (spare == 0) {
						return error.NoSpaceLeft;
					}
					buf[pos] = '\\';
					buf[pos+1] = 'n';
					pos += 2;
					spare -= 1;
				},
				'"' => {
					if (spare == 0) {
						return error.NoSpaceLeft;
					}
					buf[pos] = '\\';
					buf[pos+1] = '"';
					pos += 2;
					spare -= 1;
				},
				else => {
					buf[pos] = b;
					pos += 1;
				}
			}
		}
		self.pos = pos;
	}

	pub const FmtWriter = struct{
		kv: *Kv,

		pub const Error = anyerror;

		pub fn writeAll(self: FmtWriter, data: []const u8) !void {
			return self.kv.writeEscapeValue(data);
		}

		pub fn writeByteNTimes(self: FmtWriter, b: u8, n: usize) !void {
			return self.kv.writeByteNTimes(b, n);
		}
	};
};

fn haveSpace(len: usize, pos: usize, to_add: usize) bool {
	return len >= pos + to_add;
}

test "haveSpace" {
	for (0..10) |i| {
		try t.expectEqual(true, haveSpace(10, 0, i));
	}
	for (0..6) |i| {
		try t.expectEqual(true, haveSpace(10, 4, i));
	}

	for (11..15) |i| {
		try t.expectEqual(false, haveSpace(10, 0, i));
	}

	for (8..11) |i| {
		try t.expectEqual(false, haveSpace(10, 3, i));
	}
}

test "kv: string" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.string("key", "value");
		kv.string("other", "rehto");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=value other=rehto\n");
	}

	{
		// string requiring encoding
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.string("key", "the val\"ue");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=\"the val\\\"ue\"\n");
	}

	{
		// string requiring encoding 2
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.string("key", "a = b");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=\"a = b\"\n");
	}

	{
		// null string
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.string("key", @as(?[]const u8, null));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=null\n");
	}
}

test "kv: string buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 20});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.string("a", "abc");
		kv.string("areallyrealylongkey", "z");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=abc\n");
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("aa", "z");
		kv.string("cc", "areallylongva");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "aa=z\n");
	}

	{
		// escpace JUST fits
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("a", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=\"h\\n it \\\"goes\\\"?\"\n");
	}

	{
		// escpace overflow by 1
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("ab", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "\n");
	}
}

test "kv: stringZ" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.stringZ("key", "value");
		kv.stringZ("other", "rehto");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=value other=rehto\n");
	}

	{
		// string requiring encoding
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.stringZ("key", "the val\"ue");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=\"the val\\\"ue\"\n");
	}

	{
		// null string
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.stringZ("key", @as(?[*:0]const u8, null));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=null\n");
	}
}

test "kv: stringZ buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 20});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.stringZ("a", "abc");
		kv.stringZ("areallyrealylongkey", "z");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=abc\n");
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.stringZ("aa", "z");
		kv.stringZ("cc", "areallylongva");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "aa=z\n");
	}

	{
		// escpace JUST fits
		kv.reset();
		out.clearRetainingCapacity();
		kv.stringZ("a", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=\"h\\n it \\\"goes\\\"?\"\n");
	}

	{
		// escpace overflow by 1
		kv.reset();
		out.clearRetainingCapacity();
		kv.stringZ("ab", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "\n");
	}
}

test "kv: binary" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.binary("key", &[_]u8{9, 200, 33, 0});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=CcghAA\n");
	}

	{
		// null
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.binary("key", @as(?[]const u8, null));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=null\n");
	}
}

test "kv: binary buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.int("a", 1);
		kv.binary("toolong", &[_]u8{9, 200, 33, 0, 2});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=1\n");
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.int("a", 43);
		kv.binary("b", &[_]u8{9, 200, 0});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=43\n");
	}
}

test "kv: int" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var r = t.getRandom();
	const random = r.random();

	var buf: [100]u8 = undefined;

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(50);
	defer out.deinit();

	for (0..2000) |_| {
		const n = random.int(i64);

		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.int("over", n);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, try std.fmt.bufPrint(&buf, "over={d}\n", .{n}));
	}
}

test "kv: int special values" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// max-ish
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", 123456789123456798123456789123456789123456798123456789);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=123456789123456798123456789123456789123456798123456789\n");
	}

	{
		// min-ish
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", -123456789123456798123456789123456789123456798123456789);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=-123456789123456798123456789123456789123456798123456789\n");
	}

	{
		// null
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", @as(?u32, null));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=null\n");
	}

	{
		// comptime 0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", 0);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=0\n");
	}

	{
		 //0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", @as(i64, 0));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=0\n");
	}
}

test "kv: int buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.int("a", 33);
		kv.int("areallyrealylongkey", 99);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=33\n");
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.int("a", 43);
		kv.int("b", 9999);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=43\n");
	}
}

test "kv: bool null/true/false" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.boolean("tea", true);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "tea=Y\n");
	}

	{
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.boolean("table", false);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "table=N\n");
	}

	{
		out.clearRetainingCapacity();
		// min-ish
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.boolean("other", @as(?bool, null));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "other=null\n");
	}
}

test "kv: bool full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.int("a", 33);
		kv.boolean("areallyrealylongkey", true);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=33\n");
	}

	{
		// the 'N' overflows
		kv.reset();
		out.clearRetainingCapacity();
		kv.int("a", 43);
		kv.boolean("just", false);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=43\n");
	}
}

test "kv: float" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var r = t.getRandom();
	const random = r.random();

	var buf: [100]u8 = undefined;

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(50);
	defer out.deinit();

	for (0..2000) |_| {
		const n = random.float(f64);

		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.float("over", n);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, try std.fmt.bufPrint(&buf, "over={d}\n", .{n}));
	}
}

test "kv: float special values" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// null
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.float("n", @as(?f32, null));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=null\n");
	}

	{
		// comptime 0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.float("n", 0);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=0\n");
	}

	{
		 //0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.float("n", @as(f64, 0));
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "n=0\n");
	}
}

test "kv: float buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.float("a", 33.2);
		kv.float("arealongk", 0.33);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=33.2\n");
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.float("a", 1);
		kv.float("b", 9.424);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=1\n");
	}
}

test "kv: error" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.errK("err", error.FileNotFound);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "err=FileNotFound\n");
	}

	{
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.err(error.FileNotFound);
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "@err=FileNotFound\n");
	}
}

test "kv: ctx" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.ctx("test.kv.ctx");
		try kv.logTo(out.writer());
		try t.expectString(out.items, "@ts=9999999999999 @ctx=test.kv.ctx\n");
	}
}

test "kv: src" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.src(@src());
		try kv.logTo(out.writer());
		try t.expectString(out.items, "@ts=9999999999999 @src.file=src/kv.zig @src.fn=\"test.kv: src\" @src.line=1073\n");
	}
}

test "kv: fmt" {
	var pool = try Pool.init(t.allocator, .{.pool_size = 1});
	defer pool.deinit();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.fmt("key", "over:{d}", .{9000});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "key=\"over:9000\"\n");
	}

	{
		// string requiring encoding
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.fmt("longerkey", "over={d} !!", .{9001});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "longerkey=\"over=9001 !!\"\n");
	}
}

test "kv: fmt buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv = try Kv.init(t.allocator, .{.max_size = 20});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.string("a", "abc");
		kv.fmt("areallyrealylongkey", "z={d}", .{1});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=abc\n");
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("aa", "z");
		kv.fmt("cc", "poweris={d}", .{9000});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "aa=z\n");
	}

	{
		// escpace JUST fits
		kv.reset();
		out.clearRetainingCapacity();
		kv.fmt("a", "{s}\"{s}", .{"value 1",  "value 2"});
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "a=\"value 1\\\"value 2\"\n");
	}

	{
		// escpace overflow by 1
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("ab", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectSuffix(out.items, "\n");
	}
}
