const std = @import("std");

const t = @import("t.zig");
const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;

const mem = std.mem;
const File = std.fs.File;
const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad.Encoder;

pub const Kv = struct {
	buf: []u8,
	pos: usize,
	out: File,
	prefix_length: usize,

	const Self = @This();

	pub fn init(self: *Self, allocator: Allocator, config: Config) !void {
		const buf = try allocator.alloc(u8, config.max_size);

		var prefix_length: usize = 0;
		if (config.prefix) |prefix| {
			prefix_length = prefix.len;
			for (prefix, 0..) |b, i| {
				buf[i] = b;
			}
		}

		self.buf = buf;
		self.prefix_length = prefix_length;
		self.pos = prefix_length;
		self.out = std.io.getStdOut();
	}

	pub fn deinit(self: *Self, allocator: Allocator) void {
		allocator.free(self.buf);
	}

	pub fn reset(self: *Self) void {
		self.pos = self.prefix_length;
	}

	pub fn start(self: *Self, level: []const u8) void {
		self.writeInt("@ts", std.time.milliTimestamp());
		self.stringSafe("@l", level);
	}

	pub fn string(self: *Self, key: []const u8, nvalue: ?[]const u8) void {
		if (nvalue == null) {
			self.writeNull(key);
			return;
		}

		const value = nvalue.?;
		const originalPos = self.pos;
		if (!self.writeKeyForValue(key, value.len)) return;

		var pos = self.pos;
		const buf = self.buf;

		var must_escape = false;
		for (value) |b| {
			if (b == '=' or b == '"' or b == '\n' or b == ' ') {
				must_escape = true;
				break;
			}
		}

		if (!must_escape) {
			mem.copy(u8, buf[pos..], value);
			self.pos = pos + value.len;
			return;
		}

		// At a minimum, we'll need 2 quotes to wrap the value
		var spare = buf.len - pos - value.len - 2;

		buf[pos] = '"';
		pos += 1;

		for (value) |b| {
			switch (b) {
				'\n' => {
					if (spare == 0) {
						self.pos = originalPos;
						return;
					}
					buf[pos] = '\\';
					buf[pos+1] = 'n';
					pos += 2;
					spare -= 1;
				},
				'"' => {
					if (spare == 0) {
						self.pos = originalPos;
						return;
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
		// this has to be safe, because we already reserved the spare space for this
		// when we defined spare
		buf[pos] = '"';
		self.pos = pos + 1;
	}

	// cases where the caller is sure value does not need to be encoded
	pub fn stringSafe(self: *Self, key: []const u8, value: ?[]const u8) void {
		if (value) |v| {
			if (!self.writeKeyForValue(key, v.len)) return;
			var pos = self.pos;
			mem.copy(u8, self.buf[pos..], v);
			self.pos = pos + v.len;
		} else {
			self.writeNull(key);
		}
	}

	pub fn int(self: *Self, key: []const u8, value: anytype) void {
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

	pub fn float(self: *Self, key: []const u8, value: anytype) void {
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

	pub fn boolean(self: *Self, key: []const u8, value: anytype) void {
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

	pub fn binary(self: *Self, key: []const u8, value: ?[]const u8) void {
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

	pub fn err(self: *Self, key: []const u8, value: anyerror) void {
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

	pub fn log(self: *Self) !void {
		try self.logTo(self.out);
	}

	pub fn logCanFail(self: *Self) void {
		self.logTo(self.out) catch |e| {
			const msg = "logz: Failed to write log. Log will be dropped. Error was: {}";
			std.log.err(msg, .{e});
		};
	}

	pub fn logTo(self: *Self, out: anytype) !void {
		const pos = self.pos;
		const buf = self.buf;
		if (pos != buf.len) {
			buf[pos] = '\n';
			try out.writeAll(buf[0..pos+1]);
		} else {
			try out.writeAll(buf[0..pos]);
			try out.writeAll("\n");
		}
		self.reset();
	}

	fn writeInt(self: *Self, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		if (!self.writeKeyForValue(key, 0)) return;

		std.fmt.formatInt(value, 10, .lower, .{}, self) catch {
			self.pos = rollback_position;
	};
	}

	fn writeFloat(self: *Self, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		if (!self.writeKeyForValue(key, 0)) return;

		std.fmt.formatFloatDecimal(value, .{}, self) catch {
			self.pos = rollback_position;
		};
	}

	fn writeBool(self: *Self, key: []const u8, value: anytype) void {
		if (!self.writeKeyForValue(key, 1)) return;

		// writeKeyForValue made sure we have 1 free space
		const pos = self.pos;
		switch (value) {
			true => self.buf[pos] = 'Y',
			false => self.buf[pos] = 'N',
		}

		self.pos = pos + 1;
	}

	fn writeNull(self: *Self, key: []const u8) void {
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

	fn writeKeyForValue(self: *Self, key: []const u8, value_len: usize) bool {
		var pos = self.pos;
		const buf = self.buf;

		// +2 because we'll be appending an '='' after the key
		// and because we'll probably be pre-pending a ' '.
		if (!haveSpace(buf.len, pos, key.len+2 + value_len)) {
			return false;
		}

		if (pos != 0) {
			buf[pos] = ' ';
			pos += 1;
		}

		mem.copy(u8, buf[pos..], key);
		pos += key.len;
		buf[pos] = '=';
		self.pos = pos + 1;
		return true;
	}

	// formatInt writer interface
	pub fn writeAll(self: *Self, data: []const u8) !void {
		const pos = self.pos;
		var buf = self.buf;

		if (!haveSpace(buf.len, pos, data.len)) return error.NoSpaceLeft;

		mem.copy(u8, buf[pos..], data);
		self.pos = pos + data.len;
	}

	// formatInt writer interface
	pub fn writeByteNTimes(self: *Self, b: u8, n: usize) !void {
		const pos = self.pos;
		const buf = self.buf;
		if (!haveSpace(buf.len, pos, n)) return error.NoSpaceLeft;

		for (0..n) |i| {
			buf[pos+i] = b;
		}
		self.pos = pos + n;
	}
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
		try t.expectString("key=value other=rehto\n", out.items);
	}

	{
		// string requiring encoding
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.string("key", "the val\"ue");
		try kv.logTo(out.writer());
		try t.expectString("key=\"the val\\\"ue\"\n", out.items);
	}

	{
		// null string
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.string("key", @as(?[]const u8, null));
		try kv.logTo(out.writer());
		try t.expectString("key=null\n", out.items);
	}
}

test "kv: string buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv: Kv = undefined;
	try kv.init(t.allocator, .{.max_size = 20});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.string("a", "abc");
		kv.string("areallyrealylongkey", "z");
		try kv.logTo(out.writer());
		try t.expectString("a=abc\n", out.items);
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("aa", "z");
		kv.string("cc", "areallylongva");
		try kv.logTo(out.writer());
		try t.expectString("aa=z\n", out.items);
	}

	{
		// escpace JUST fits
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("a", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectString("a=\"h\\n it \\\"goes\\\"?\"\n", out.items);
	}

	{
		// escpace overflow by 1
		kv.reset();
		out.clearRetainingCapacity();
		kv.string("ab", "h\n it \"goes\"?");
		try kv.logTo(out.writer());
		try t.expectString("\n", out.items);
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
		try t.expectString("key=CcghAA\n", out.items);
	}

	{
		// null
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);

		kv.binary("key", @as(?[]const u8, null));
		try kv.logTo(out.writer());
		try t.expectString("key=null\n", out.items);
	}
}

test "kv: binary buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv: Kv = undefined;
	try kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.int("a", 1);
		kv.binary("toolong", &[_]u8{9, 200, 33, 0, 2});
		try kv.logTo(out.writer());
		try t.expectString("a=1\n", out.items);
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.int("a", 43);
		kv.binary("b", &[_]u8{9, 200, 0});
		try kv.logTo(out.writer());
		try t.expectString("a=43\n", out.items);
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
		try t.expectString(try std.fmt.bufPrint(&buf, "over={d}\n", .{n}), out.items);
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
		try t.expectString("n=123456789123456798123456789123456789123456798123456789\n", out.items);
	}

	{
		// min-ish
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", -123456789123456798123456789123456789123456798123456789);
		try kv.logTo(out.writer());
		try t.expectString("n=-123456789123456798123456789123456789123456798123456789\n", out.items);
	}

	{
		// null
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", @as(?u32, null));
		try kv.logTo(out.writer());
		try t.expectString("n=null\n", out.items);
	}

	{
		// comptime 0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", 0);
		try kv.logTo(out.writer());
		try t.expectString("n=0\n", out.items);
	}

	{
		 //0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.int("n", @as(i64, 0));
		try kv.logTo(out.writer());
		try t.expectString("n=0\n", out.items);
	}
}

test "kv: int buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv: Kv = undefined;
	try kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.int("a", 33);
		kv.int("areallyrealylongkey", 99);
		try kv.logTo(out.writer());
		try t.expectString("a=33\n", out.items);
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.int("a", 43);
		kv.int("b", 9999);
		try kv.logTo(out.writer());
		try t.expectString("a=43\n", out.items);
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
		try t.expectString("tea=Y\n", out.items);
	}

	{
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.boolean("table", false);
		try kv.logTo(out.writer());
		try t.expectString("table=N\n", out.items);
	}

	{
		out.clearRetainingCapacity();
		// min-ish
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.boolean("other", @as(?bool, null));
		try kv.logTo(out.writer());
		try t.expectString("other=null\n", out.items);
	}
}

test "kv: bool full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv: Kv = undefined;
	try kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.int("a", 33);
		kv.boolean("areallyrealylongkey", true);
		try kv.logTo(out.writer());
		try t.expectString("a=33\n", out.items);
	}

	{
		// the 'N' overflows
		kv.reset();
		out.clearRetainingCapacity();
		kv.int("a", 43);
		kv.boolean("just", false);
		try kv.logTo(out.writer());
		try t.expectString("a=43\n", out.items);
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
		try t.expectString(try std.fmt.bufPrint(&buf, "over={d}\n", .{n}), out.items);
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
		try t.expectString("n=null\n", out.items);
	}

	{
		// comptime 0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.float("n", 0);
		try kv.logTo(out.writer());
		try t.expectString("n=0\n", out.items);
	}

	{
		 //0
		out.clearRetainingCapacity();
		var kv = pool.acquire() orelse unreachable;
		defer pool.release(kv);
		kv.float("n", @as(f64, 0));
		try kv.logTo(out.writer());
		try t.expectString("n=0\n", out.items);
	}
}

test "kv: float buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var kv: Kv = undefined;
	try kv.init(t.allocator, .{.max_size = 10});
	defer kv.deinit(t.allocator);

	{
		// key is too large
		kv.float("a", 33.2);
		kv.float("arealongk", 0.33);
		try kv.logTo(out.writer());
		try t.expectString("a=33.2\n", out.items);
	}

	{
		// value is too large
		kv.reset();
		out.clearRetainingCapacity();
		kv.float("a", 1);
		kv.float("b", 9.424);
		try kv.logTo(out.writer());
		try t.expectString("a=1\n", out.items);
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

		kv.err("err", error.FileNotFound);
		try kv.logTo(out.writer());
		try t.expectString("err=FileNotFound\n", out.items);
	}

}
