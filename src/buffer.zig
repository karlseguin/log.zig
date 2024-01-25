const std = @import("std");

const Config = @import("config.zig").Config;

const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

const M = @This();

pub const Buffer = struct {
	// position in buf to write to next
	// (or the position to read up to)
	pos: usize,

	// either points to static or points to a buffer from the pool
	buf: []u8,

	// static buffer that's re-used from one log to the other
	static: []u8,

	// the pool to goto to get larger buffers
	pool: *M.Pool,

	// If writing any part of the attribute fails, this is the information we
	// need to bring the buffer back to the state it was in before we started
	// writing the attribute
	rewind: ?RewindState = null,

	pub const Pool = M.Pool;

	pub fn reset(self: *Buffer, pos: usize) void {
		self.pos = pos;
		if (self.buf.ptr != self.static.ptr) {
			self.pool.releaseLarge(self.buf);
			self.buf = self.static;
		}
	}

	pub fn deinit(self: *Buffer) void {
		const pool = self.pool;
		const static = self.static;
		if (self.buf.ptr != static.ptr) {
			pool.releaseLarge(self.buf);
		}
		pool.allocator.free(self.static);
	}

	pub fn writeAll(self: *Buffer, data: []const u8) !void {
		switch (self.sizeCheck(data.len)) {
			.buf => self.writeAllBuf(data),
			.acquire_large => |available| {
				const larger = (self.pool.acquireLarge() catch return error.NoSpaceLeft) orelse return error.NoSpaceLeft;

				const pos = self.pos;
				const buf = self.buf;

				// Copy what fits in our static buffer
				@memcpy(buf[pos..], data[0..available]);

				// Copy the rest in our larger buffer
				const end = data.len - available;
				@memcpy(larger[0..end], data[available..]);
				self.buf = larger;
				self.pos = end;
			},
			.none => return error.NoSpaceLeft,
		}
	}

	pub fn writeByte(self: *Buffer, b: u8) !void {
		const pos = self.pos;
		const buf = self.buf;

		if (buf.len >= pos + 1) {
			buf[pos] = b;
			self.pos = pos + 1;
			return;
		}

		if (buf.ptr != self.static.ptr) {
			return error.NoSpaceLeft;
		}

		const large = (self.pool.acquireLarge() catch return error.NoSpaceLeft) orelse return error.NoSpaceLeft;
		large[0] = b;
		self.buf = large;
		self.pos = 1;
	}

	pub fn writeByteNTimes(self: *Buffer, b: u8, n: usize) !void {
		const pos = self.pos;
		const buf = self.buf;

		switch (self.sizeCheck(n)) {
			.buf => {
				for (0..n) |i| {
					buf[pos+i] = b;
				}
				self.pos = pos + n;
			},
			.acquire_large => |available| {
				const larger = (self.pool.acquireLarge() catch return error.NoSpaceLeft) orelse return error.NoSpaceLeft;

				for (0..available) |i| {
					buf[pos+i] = b;
				}

				const remaining = n - available;
				for (0..remaining) |i| {
					larger[i] = b;
				}
				self.buf = larger;
				self.pos = remaining;
			},
			.none => return error.NoSpaceLeft,
		}
	}

	pub fn writeBytesNTimes(self: *Buffer, data: []const u8, n: usize) !void {
		if (self.sizeCheck(data.len * n) == .none) {
			return;
		}

		for (0..n) |_| {
			try self.writeAll(data);
		}
	}

	pub fn writeAllBuf(self: *Buffer, data: []const u8) void {
		const pos = self.pos;
		const end = pos + data.len;
		@memcpy(self.buf[pos..end], data);
		self.pos = end;
	}

	pub fn writeByteBuf(self: *Buffer, b: u8) void {
		const pos = self.pos;
		self.buf[pos] = b;
		self.pos = pos + 1;
	}

	// Loggers won't partially write attributes (key=>value pairs). If we don't
	// have enough space to write any part of the key, any part of the value or
	// any delimiter, then the entire attribute is skipped. An AttributeWriter
	// manages this rollback logic while exposing a normal write API
	pub fn attributeWriter(self: *Buffer, len: usize, exact: bool) ?AttributeWriter {
		switch (self.sizeCheck(len)) {
			.none => return null,
			else => |other| return .{
				.buffer = self,
				._rollback = false,
				.initial_pos = self.pos,
				.fits_in_buf = exact and other == .buf,
				.initial_static = self.buf.ptr == self.static.ptr,
			},
		}
	}

	const SizeCheckResult = union(enum) {
		// we have space for the requested data in the current buffer
		buf: void,

		// we cannot accomodate the requested data
		none: void,

		// we have space for the requested data if we acquire a large buffer
		acquire_large: usize,
	};

	pub fn sizeCheck(self: *Buffer, n: usize) SizeCheckResult {
		const buf = self.buf;

		const available = buf.len - self.pos;
		if (available >= n) {
			return .{.buf = {}};
		}

		if (buf.ptr == self.static.ptr and available + self.pool.large_buffer_size >= n) {
			// if the caller acquires a large buffer, we'll have space
			return .{.acquire_large = available};
		}

		return .{.none = {}};
	}

	pub const RewindState = struct {
		pos: usize,
		static: bool,
	};

	// We're beginning an operation that we might need to rollback, we need
	// to capture the current state so that we can rollback
	pub fn begin(self: *Buffer) RewindState {
		return .{
			.pos = self.pos,
			.static = self.buf.ptr == self.static.ptr,
		};
	}

	// Need to rollback based on the state
	pub fn rollback(self: *Buffer, rewind: RewindState) void {
		if (rewind.static) {
			if (self.buf.ptr != self.static.ptr) {
				// This is the only special case. When we began this operation, we
				// were using the static buffer. However, during the operation, we acquired
				// a large buffer. We need to release the large buffer and return to our
				// static buffer.
				self.pool.releaseLarge(self.buf);
				self.buf = self.static;
			}
		}
		self.pos = rewind.pos;
	}
};

pub const AttributeWriter = struct {
	buffer: *Buffer,

	// should we rollback when done() is called
	_rollback: bool,

	// the position we were at before we started this attribute
	initial_pos: usize,

	// before we started this attribute, were we using the static buffer
	initial_static: bool,

	// There are cases where we know the full attribute will fit in buffer.buf.
	// Namely, for any case where we know the length of the attribute, we can
	// determine if it'll fit in buf, or if we'll need to acquire a larger buf
	// Common case that's worth optimizing;
	fits_in_buf: bool,

	pub fn writeAll(self: *AttributeWriter, data: []const u8) void {
		var buffer = self.buffer;
		const pos = buffer.pos;
		if (self.fits_in_buf) {
			const end = pos + data.len;
			@memcpy(buffer.buf[pos..end], data);
			buffer.pos = end;
			return;
		}

		buffer.writeAll(data) catch {
			self._rollback = true;
		};
	}

	// optimization for the common case that we have a string followed by a single byte
	// (like a separator)
	pub fn writeAllB(self: *AttributeWriter, data: []const u8, suffix: u8) void {
		var buffer = self.buffer;
		const pos = buffer.pos;
		if (self.fits_in_buf) {
			const end = pos + data.len;
			@memcpy(buffer.buf[pos..end], data);
			buffer.buf[end] = suffix;
			buffer.pos = end + 1;
			return;
		}

		buffer.writeAll(data) catch {
			self._rollback = true;
			return;
		};

		buffer.writeByte(suffix) catch {
			self._rollback = true;
			return;
		};
	}

	// optimization for the common case that we have a string followed by another string
	pub fn writeAllAll(self: *AttributeWriter, data: []const u8, suffix: []const u8) void {
		var buffer = self.buffer;
		const pos = buffer.pos;
		if (self.fits_in_buf) {
			const end1 = pos + data.len;
			@memcpy(buffer.buf[pos..end1], data);

			const end2 = end1 + suffix.len;
			@memcpy(buffer.buf[end1..end2], suffix);
			buffer.pos = end2;
			return;
		}

		buffer.writeAll(data) catch {
			self._rollback = true;
			return;
		};

		buffer.writeAll(suffix) catch {
			self._rollback = true;
			return;
		};
	}

	pub fn writeByte(self: *AttributeWriter, b: u8) void {
		const pos = self.buffer.pos;
		if (self.fits_in_buf) {
			self.buffer.buf[pos] = b;
			self.buffer.pos = pos + 1;
			return;
		}

		self.buffer.writeByte(b) catch {
			self._rollback = true;
		};
	}

	pub fn rollback(self: *AttributeWriter) void {
		self._rollback = true;
		self.done();
	}

	pub fn done(self: *AttributeWriter) void {
		if (self._rollback == false) {
			return;
		}

		var buffer = self.buffer;
		buffer.pos = self.initial_pos;
		if (self.initial_static == false) {
			// if we started this attribute with a large buffer, then we need to keep
			// it around
			return;
		}

		if (buffer.buf.ptr != buffer.static.ptr) {
			// This is the only special case. When we began this operation, we
			// were using the static buffer. However, during the operation, we acquired
			// a large buffer. We need to release the large buffer and return to our
			// static buffer.
			buffer.pool.releaseLarge(buffer.buf);
			buffer.buf = buffer.static;
		}
	}
};

pub const Pool = struct {
	mutex: Mutex,
	buffers: [][]u8,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,
	large_buffer_size: usize,
	strategy: Config.LargeBufferStrategy,

	pub fn init(allocator: Allocator, config: *const Config) !Pool {
		const large_buffer_size = config.large_buffer_size;
		const large_buffer_count = if (large_buffer_size == 0) 0 else config.large_buffer_count;
		const buffers = try allocator.alloc([]u8, large_buffer_count);
		errdefer allocator.free(buffers);

		var initialized: usize = 0;
		errdefer {
			for (0..initialized) |i| {
				allocator.free(buffers[i]);
			}
		}

		for (0..large_buffer_count) |i| {
			buffers[i] = try allocator.alloc(u8, large_buffer_size);
			initialized += 1;
		}

		return .{
			.mutex = .{},
			.buffers = buffers,
			.allocator = allocator,
			.available = large_buffer_count,
			.buffer_size = config.buffer_size,
			.strategy = if (large_buffer_count == 0) .drop else config.large_buffer_strategy,
			.large_buffer_size = if (large_buffer_count == 0) 0 else large_buffer_size,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.buffers) |buf| {
			allocator.free(buf);
		}
		allocator.free(self.buffers);
	}

	pub fn create(self: *Pool) !Buffer {
		const static = try self.allocator.alloc(u8, self.buffer_size);
		return .{
			.pos = 0,
			.pool = self,
			.buf = static,
			.static = static,
		};
	}

	pub fn acquireLarge(self: *Pool) !?[]u8 {
		const buffers = self.buffers;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			self.mutex.unlock();
			if (self.strategy == .drop) {
				return null;
			}
			return try self.allocator.alloc(u8, self.large_buffer_size);
		}

		const index = available - 1;
		const buf = buffers[index];
		self.available = index;
		self.mutex.unlock();
		return buf;
	}

	pub fn releaseLarge(self: *Pool, buf: []u8) void {
		var buffers = self.buffers;

		self.mutex.lock();
		const available = self.available;
		if (available == buffers.len) {
			self.mutex.unlock();
			self.allocator.free(buf);
			return;
		}
		buffers[available] = buf;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

const t = @import("t.zig");
// Buffer is extensively tested through the LogFmt and Json tests

test "pool: create" {
	var p = try Pool.init(t.allocator, &.{.large_buffer_count = 2, .large_buffer_size = 15, .buffer_size = 10});
	defer p.deinit();

	var b = try p.create();
	defer b.deinit();
	try t.expectEqual(10, b.buf.len);
	try t.expectEqual(10, b.static.len);
	try t.expectEqual(true, b.buf.ptr == b.static.ptr);
	try t.expectEqual(true, b.pool == &p);
}

test "pool: acquire and release with drop strategy" {
	var p = try Pool.init(t.allocator, &.{.large_buffer_count = 2, .large_buffer_size = 15, .buffer_size = 10, .large_buffer_strategy = .drop});
	defer p.deinit();

	const i1a = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i1a.len);
	const i2a = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i2a.len);

	try t.expectEqual(false, i1a.ptr == i2a.ptr);

	try t.expectEqual(null, (try p.acquireLarge()));

	p.releaseLarge(i1a);
	const i1b = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i1b.len);
	try t.expectEqual(true, i1a.ptr == i1b.ptr);

	p.releaseLarge(i2a);
	p.releaseLarge(i1b);
}

test "pool: acquire and release with create strategy" {
	var p = try Pool.init(t.allocator, &.{.large_buffer_count = 2, .large_buffer_size = 15, .buffer_size = 10});
	defer p.deinit();

	const i1a = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i1a.len);
	const i2a = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i2a.len);

	const i3a = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i2a.len);

	try t.expectEqual(false, i1a.ptr == i2a.ptr);
	try t.expectEqual(false, i1a.ptr == i3a.ptr);
	try t.expectEqual(false, i2a.ptr == i3a.ptr);

	p.releaseLarge(i1a);
	const i1b = (try p.acquireLarge()) orelse unreachable;
	try t.expectEqual(15, i1b.len);
	try t.expectEqual(true, i1a.ptr == i1b.ptr);

	p.releaseLarge(i2a);
	p.releaseLarge(i1b);
	p.releaseLarge(i3a);
}

test "pool: threadsafety" {
	var p = try Pool.init(t.allocator, &.{.large_buffer_count = 3, .large_buffer_size = 5, .buffer_size = 2});
	defer p.deinit();

	// initialize this to 0 since we're asserting that it's 0
	for (p.buffers) |buffer| {
		buffer[0] = 0;
	}

	const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t3 = try std.Thread.spawn(.{}, testPool, .{&p});

	t1.join(); t2.join(); t3.join();
}

fn testPool(p: *Pool) void {
	var r = t.getRandom();
	const random = r.random();

	for (0..5000) |_| {
		var buf = p.acquireLarge() catch unreachable orelse unreachable;
		// no other thread should have set this to 255
		std.debug.assert(buf[0] == 0);

		buf[0] = 255;
		std.time.sleep(random.uintAtMost(u32, 100000));
		buf[0] = 0;
		p.releaseLarge(buf);
	}
}
