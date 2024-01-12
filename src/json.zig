const std = @import("std");

const logz = @import("logz.zig");
const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad.Encoder;

const t = @import("t.zig");
const timestamp = if (t.is_test) t.timestamp else std.time.milliTimestamp;

pub const Json = struct {
	buf: []u8,
	pos: usize,
	out: File,
	lvl: logz.Level,
	prefix_length: usize,
	multiuse_length: ?usize,

	pub fn init(allocator: Allocator, config: Config) !Json {
		const buf = try allocator.alloc(u8, config.max_size);
		errdefer allocator.free(buf);

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

	pub fn deinit(self: *Json, allocator: Allocator) void {
		allocator.free(self.buf);
	}

	pub fn multiuse(self: *Json) void {
		self.multiuse_length = self.pos;
	}

	pub fn reset(self: *Json) void {
		self.lvl = .None;
		self.multiuse_length = null;
		self.pos = self.prefix_length;
	}

	pub fn reuse(self: *Json) void {
		self.lvl = .None;
		self.pos = if (self.multiuse_length) |l| l else 0;
	}

	pub fn level(self: *Json, lvl: logz.Level) void {
		self.lvl = lvl;
	}

	pub fn ctx(self: *Json, value: []const u8) void {
		self.stringSafe("@ctx", value);
	}

	pub fn src(self: *Json, value: std.builtin.SourceLocation) void {
		self.writeObject("@src", .{.file = value.file, .@"fn" = value.fn_name, .line = value.line});
	}

	pub fn string(self: *Json, key: []const u8, nvalue: ?[]const u8) void {
		const value = nvalue orelse {
			self.writeNull(key);
			return;
		};
		const reset_position = self.pos;
		// +2 because we'll need to quote the value (we might need more space)
		// that this, but we'll do that check in writeStringValue
		if (self.writeKeyForValue(key, value.len + 2) == false) {
			return;
		}
		self.writeStringValue(value, reset_position);
	}

	pub fn fmt(self: *Json, key: []const u8, comptime format: []const u8, values: anytype) void {
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

		std.fmt.format(FmtWriter{.json = self}, format, values) catch {
			self.pos = initial_pos;
			return;
		};

		pos = self.pos;
		if (!haveSpace(buf.len, pos, 1)) {
			self.pos = initial_pos;
			return;
		}

		buf[pos] = '"';
		self.pos = pos + 1;
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

		if (!self.writeKeyForValue(key, value.len + 2)) return;
		var pos = self.pos;
		const buf = self.buf;

		buf[pos] = '"';
		pos += 1;

		const end = pos + value.len;
		@memcpy(buf[pos..end], value);
		buf[end] = '"';
		self.pos = end + 1;
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

	pub fn float(self: *Json, key: []const u8, value: anytype) void {
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

	pub fn boolean(self: *Json, key: []const u8, value: anytype) void {
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

	pub fn binary(self: *Json, key: []const u8, nvalue: ?[]const u8) void {
		const value = nvalue orelse {
			self.writeNull(key);
			return;
		};

		const enc_len = b64.calcSize(value.len);
		if (!self.writeKeyForValue(key, enc_len + 2)) return;

		// base64 encoded value never requires escaping, yay.
		const pos = self.pos;
		const buf = self.buf;
		buf[pos] = '"';
		_ = b64.encode(self.buf[pos+1..], value);
		const end = pos + enc_len + 1;
		buf[end] = '"';
		self.pos = end + 1;
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
		const pos = self.pos;
		const buf = self.buf;
		const prefix_length = self.prefix_length;

		var meta_start: usize = 0;
		if (prefix_length > 0) {
			try out.writeAll(buf[0..prefix_length]);
			// prefix is an advanced feature, and when set, it needs to contain
			// the start of a valid json object.
			meta_start = 1;
		}

		var meta: [34]u8 = undefined;
		@memcpy(meta[0..7], "{\"@ts\":");
		_ = std.fmt.formatIntBuf(meta[7..], timestamp(), 10, .lower, .{});

		const meta_length: usize = switch (self.lvl) {
			.Debug => blk: {
				@memcpy(meta[20..], ", \"@l\":\"DEBUG\"");
				break :blk 34;
			},
			.Info => blk: {
				@memcpy(meta[20..33], ", \"@l\":\"INFO\"");
				break :blk 33;
			},
			.Warn => blk: {
				@memcpy(meta[20..33], ", \"@l\":\"WARN\"");
				break :blk 33;
			},
			.Error => blk: {
				@memcpy(meta[20..], ", \"@l\":\"ERROR\"");
				break :blk 34;
			},
			.Fatal => blk: {
				@memcpy(meta[20..], ", \"@l\":\"FATAL\"");
				break :blk 34;
			},
			else => blk: {
				break :blk 20;
			},
		};

		try out.writeAll(meta[meta_start..meta_length]);

		if (pos < buf.len - 1) {
			buf[pos] = '}';
			buf[pos+1] = '\n';
			try out.writeAll(buf[prefix_length..pos+2]);
		} else {
			try out.writeAll(buf[prefix_length..pos]);
			try out.writeAll("}\n");
		}
	}

	fn writeInt(self: *Json, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		if (!self.writeKeyForValue(key, 0)) return;

		std.fmt.formatInt(value, 10, .lower, .{}, self) catch {
			self.pos = rollback_position;
		};
	}

	fn writeFloat(self: *Json, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		if (!self.writeKeyForValue(key, 0)) return;

		std.fmt.formatFloatDecimal(value, .{}, self) catch {
			self.pos = rollback_position;
		};
	}

	fn writeBool(self: *Json, key: []const u8, value: anytype) void {
		switch (value) {
			true => {
				if (!self.writeKeyForValue(key, 4)) return;
				const pos = self.pos;
				const end = pos + 4;
				@memcpy(self.buf[pos..end], "true");
				self.pos = end;
			},
			false => {
				if (!self.writeKeyForValue(key, 5)) return;
				const pos = self.pos;
				const end = pos + 5;
				@memcpy(self.buf[pos..end], "false");
				self.pos = end;
			}
		}
	}

	fn writeNull(self: *Json, key: []const u8) void {
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

	fn writeObject(self: *Json, key: []const u8, value: anytype) void {
		const rollback_position = self.pos;
		// we don'tk now the serialized length of value, but it'll at least need an
		// opening and closing brace
		if (!self.writeKeyForValue(key, 2)) return;

		std.json.stringify(value, .{}, Writer{.json = self}) catch {
			self.pos = rollback_position;
		};
	}

	fn writeKeyForValue(self: *Json, key: []const u8, value_len: usize) bool {
		var pos = self.pos;
		const buf = self.buf;

		// +1 the comma
		// +1 the space
		// +1 the quote
		// +1 the quote
		// +1 the colon
		// = +5
		if (pos + key.len + 5 + value_len > buf.len) return false;

		buf[pos] = ',';
		buf[pos+1] = ' ';
		buf[pos+2] = '"';
		pos += 3;

		const end = pos + key.len;
		@memcpy(buf[pos..end], key);
		buf[end] = '"';
		buf[end+1] = ':';
		self.pos = end + 2;
		return true;
	}

	pub fn writeAll(self: *Json, data: []const u8) !void {
		const pos = self.pos;
		const buf = self.buf;

		if (!haveSpace(buf.len, pos, data.len)) return error.NoSpaceLeft;

		@memcpy(buf[pos..pos+data.len], data);
		self.pos = pos + data.len;
	}

	pub fn writeByte(self: *Json, b: u8) !void {
		const pos = self.pos;
		const buf = self.buf;

		if (!haveSpace(buf.len, pos, 1)) return error.NoSpaceLeft;

		buf[pos] = b;
		self.pos = pos + 1;
	}

	// formatInt writer interface
	pub fn writeByteNTimes(self: *Json, b: u8, n: usize) !void {
		const pos = self.pos;
		const buf = self.buf;
		if (!haveSpace(buf.len, pos, n)) return error.NoSpaceLeft;

		for (0..n) |i| {
			buf[pos+i] = b;
		}
		self.pos = pos + n;
	}

	fn writeStringValue(self: *Json, value: []const u8, rollback_position: usize) void {
		std.json.encodeJsonString(value, .{}, self) catch {
			self.pos = rollback_position;
		};
	}

	pub const FmtWriter = struct{
		json: *Json,

		pub const Error = anyerror;

		pub fn writeAll(self: FmtWriter, data: []const u8) !void {
			return std.json.encodeJsonStringChars(data, .{}, self.json);
		}

		pub fn writeByteNTimes(self: FmtWriter, b: u8, n: usize) !void {
			return self.json.writeByteNTimes(b, n);
		}
	};

	pub const Writer = struct{
		json: *Json,

		pub const Error = anyerror;

		pub fn writeByte(self: Writer, b: u8) !void {
			return self.json.writeByte(b);
		}

		pub fn writeByteNTimes(self: Writer, b: u8, n: usize) !void {
			return self.json.writeByteNTimes(b, n);
		}

		pub fn writeAll(self: Writer, value: []const u8) !void {
			return self.json.writeAll(value);
		}


		pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
			 return std.fmt.format(self, format, args);
		}
	};
};

fn haveSpace(len: usize, pos: usize, to_add: usize) bool {
	return len >= pos + to_add;
}

test "json: haveSpace" {
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

test "json: string" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	{
		json.string("key", "value");
		json.string("other", "rehto");
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.key = "value", .other = "rehto"});
	}

	{
		// string requiring encoding
		json.reset();
		out.clearRetainingCapacity();

		json.string("key", "the val\"ue");
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.key = "the val\"ue"});
		try t.expectSuffix(out.items, ", \"key\":\"the val\\\"ue\"}\n");
	}

	{
		// string requiring encoding 2
		json.reset();
		out.clearRetainingCapacity();

		json.string("key", "a = b");
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.key = "a = b"});
	}

	{
		// null string
		json.reset();
		out.clearRetainingCapacity();

		json.string("key", @as(?[]const u8, null));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":null}\n");
	}
}

test "json: string buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 20});
	defer json.deinit(t.allocator);

	{
		// key is too large
		json.string("a", "abc");
		json.string("areallyrealylongkey", "z");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":\"abc\"}\n");
	}

	{
		// value is too large
		json.reset();
		out.clearRetainingCapacity();
		json.string("aa", "z");
		json.string("cc", "areallylongva");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"aa\":\"z\"}\n");
	}

	{
		// escpace JUST fits
		json.reset();
		out.clearRetainingCapacity();
		json.string("a", "h\n \"goe\"?");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":\"h\\n \\\"goe\\\"?\"}\n");
	}

	{
		// escpace overflow by 1
		json.reset();
		out.clearRetainingCapacity();
		json.string("a", "h\n \"goes\"?");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, "{\"@ts\":9999999999999}\n");
	}
}

test "json: stringZ" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		json.stringZ("key", "value");
		json.stringZ("other", "rehto");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":\"value\", \"other\":\"rehto\"}\n");
	}

	{
		// string requiring encoding
		json.reset();
		out.clearRetainingCapacity();

		json.stringZ("key", "the val\"ue");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":\"the val\\\"ue\"}\n");
	}

	{
		// null string
		json.reset();
		out.clearRetainingCapacity();

		json.stringZ("key", @as(?[*:0]const u8, null));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":null}\n");
	}
}

test "json: stringZ buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 20});
	defer json.deinit(t.allocator);

	{
		// key is too large
		json.stringZ("a", "abc");
		json.stringZ("areallyrealylongkey", "z");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":\"abc\"}\n");
	}

	{
		// value is too large
		json.reset();
		out.clearRetainingCapacity();
		json.stringZ("aa", "z");
		json.stringZ("cc", "areallylongva");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"aa\":\"z\"}\n");
	}

	{
		// escpace JUST fits
		json.reset();
		out.clearRetainingCapacity();
		json.stringZ("a", "h\n \"goe\"?");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":\"h\\n \\\"goe\\\"?\"}\n");
	}

	{
		// escpace overflow by 1
		json.reset();
		out.clearRetainingCapacity();
		json.stringZ("ab", "hab\n \"g\"?");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, "{\"@ts\":9999999999999}\n");
	}
}

test "json: binary" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		json.binary("key", &[_]u8{9, 200, 33, 0});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":\"CcghAA\"}\n");
	}

	{
		// null
		json.reset();
		out.clearRetainingCapacity();

		json.binary("key", @as(?[]const u8, null));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":null}\n");
	}
}

test "json: binary buffer full" {
	var json = try Json.init(t.allocator, .{.max_size = 10});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// key is too large
		json.int("a", 1);
		json.binary("toolong", &[_]u8{9, 200, 33, 0, 2});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":1}\n");
	}

	{
		// value is too large
		json.reset();
		out.clearRetainingCapacity();
		json.int("a", 43);
		json.binary("b", &[_]u8{9, 200, 0});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":43}\n");
	}
}

test "json: int" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var r = t.getRandom();
	const random = r.random();

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(50);
	defer out.deinit();

	for (0..2000) |_| {
		const n = random.int(i64);

		json.reset();
		out.clearRetainingCapacity();

		json.int("over", n);
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.over = n});
	}
}

test "json: int special values" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// max-ish
		json.int("n", 123456789123456798123456789123456789123456798123456789);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":123456789123456798123456789123456789123456798123456789}\n");
	}

	{
		// min-ish
		json.reset();
		out.clearRetainingCapacity();
		json.int("n", -123456789123456798123456789123456789123456798123456789);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":-123456789123456798123456789123456789123456798123456789}\n");
	}

	{
		// null
		json.reset();
		out.clearRetainingCapacity();
		json.int("n", @as(?u32, null));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":null}\n");
	}

	{
		// comptime 0
		json.reset();
		out.clearRetainingCapacity();
		json.int("n", 0);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":0}\n");
	}

	{
		 //0
		json.reset();
		out.clearRetainingCapacity();
		json.int("n", @as(i64, 0));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":0}\n");
	}
}

test "json: int buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 10});
	defer json.deinit(t.allocator);

	{
		// key is too large
		json.int("a", 33);
		json.int("areallyrealylongkey", 99);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":33}\n");
	}

	{
		// value is too large
		json.reset();
		out.clearRetainingCapacity();
		json.int("a", 43);
		json.int("b", 9999);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":43}\n");
	}
}

test "json: bool null/true/false" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		json.boolean("tea", true);
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.tea = true});
	}

	{
		json.reset();
		out.clearRetainingCapacity();
		json.boolean("table", false);
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.table = false});
	}

	{
		// min-ish
		json.reset();
		out.clearRetainingCapacity();
		json.boolean("other", @as(?bool, null));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"other\":null}\n");
	}
}

test "json: bool full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 10});
	defer json.deinit(t.allocator);

	{
		// key is too large
		json.int("a", 33);
		json.boolean("areallyrealylongkey", true);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":33}\n");
	}

	{
		json.reset();
		out.clearRetainingCapacity();
		json.int("a", 43);
		json.boolean("just", false);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":43}\n");
	}
}

test "json: float" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var r = t.getRandom();
	const random = r.random();


	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(50);
	defer out.deinit();

	for (0..2000) |_| {
		const n = random.float(f64);

		json.reset();
		out.clearRetainingCapacity();

		json.float("over", n);
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.over = n});
	}
}

test "json: float special values" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// null
		out.clearRetainingCapacity();
		json.float("n", @as(?f32, null));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":null}\n");
	}

	{
		// comptime 0
		json.reset();
		out.clearRetainingCapacity();
		json.float("n", 0);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":0}\n");
	}

	{
		 //0
		 json.reset();
		out.clearRetainingCapacity();
		json.float("n", @as(f64, 0));
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"n\":0}\n");
	}
}

test "json: float buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 10});
	defer json.deinit(t.allocator);

	{
		// key is too large
		json.float("a", 33.2);
		json.float("arealongk", 0.33);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":33.2}\n");
	}

	{
		// value is too large
		json.reset();
		out.clearRetainingCapacity();
		json.float("a", 1);
		json.float("b", 9.424);
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":1}\n");
	}
}

test "json: error" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		json.errK("err2", error.FileNotFound);
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.err2 = "FileNotFound"});
	}

	{
		json.reset();
		out.clearRetainingCapacity();

		json.err(error.FileNotFound);
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.@"@err" = "FileNotFound"});
	}
}

test "json: ctx" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		json.reset();
		json.ctx("test.json.ctx");
		try json.logTo(out.writer());
		try t.expectJson(out.items, .{.@"@ts" = 9999999999999, .@"@ctx" = "test.json.ctx"});
		try t.expectString(out.items, "{\"@ts\":9999999999999, \"@ctx\":\"test.json.ctx\"}\n");
	}
}

test "json: src" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		const src = @src();
		json.src(src);
		try json.logTo(out.writer());

		try t.expectJson(out.items, .{.@"@ts" = 9999999999999, .@"@src" = .{
			.line = src.line,
			.@"fn" = "test.json: src",
			.file = "src/json.zig",
		}});
	}
}

test "json: fmt" {
	var json = try Json.init(t.allocator, .{.max_size = 100});
	defer json.deinit(t.allocator);

	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	{
		// normal strings
		json.fmt("key", "over:{d}", .{9000});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"key\":\"over:9000\"}\n");
	}

	{
		// string requiring encoding
		json.reset();
		out.clearRetainingCapacity();

		json.fmt("longerkey", "over={d} !!", .{9001});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"longerkey\":\"over=9001 !!\"}\n");
	}
}

test "json: fmt buffer full" {
	var out = std.ArrayList(u8).init(t.allocator);
	try out.ensureTotalCapacity(100);
	defer out.deinit();

	var json = try Json.init(t.allocator, .{.max_size = 20});
	defer json.deinit(t.allocator);

	{
		// key is too large
		json.string("a", "abc");
		json.fmt("areallyrealylongkey", "z={d}", .{1});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":\"abc\"}\n");
	}

	{
		// value is too large
		json.reset();
		out.clearRetainingCapacity();
		json.string("aa", "z");
		json.fmt("cc", "poweris={d}", .{9000});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"aa\":\"z\"}\n");
	}

	{
		// escpace JUST fits
		json.reset();
		out.clearRetainingCapacity();
		json.fmt("a", "{s}\"{s}", .{"val 1",  "val 2"});
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, ", \"a\":\"val 1\\\"val 2\"}\n");
	}

	{
		// escpace overflow by 1
		json.reset();
		out.clearRetainingCapacity();
		json.string("ab", "h\n it \"goes\"?");
		try json.logTo(out.writer());
		try t.expectSuffix(out.items, "{\"@ts\":9999999999999}\n");
	}
}
