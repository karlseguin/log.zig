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
		const pos = self.pos;
		const buf = self.buf;

		switch (self.sizeCheck(data.len)) {
			.buf => {
				const end = pos + data.len;
				@memcpy(buf[pos..end], data);
				self.pos = end;
				return;
			},
			.acquire_large => |available| {
				const larger = self.pool.acquireLarge() orelse return error.NoSpaceLeft;

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

		const large = self.pool.acquireLarge() orelse return error.NoSpaceLeft;
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
				const larger = self.pool.acquireLarge() orelse return error.NoSpaceLeft;

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

pub const Pool = struct {
	mutex: Mutex,
	buffers: [][]u8,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,
	large_buffer_size: usize,

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

	pub fn acquireLarge(self: *Pool) ?[]u8 {
		const buffers = self.buffers;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			self.mutex.unlock();
			return null;
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

test "pool: acquire and release" {
	var p = try Pool.init(t.allocator, &.{.large_buffer_count = 2, .large_buffer_size = 15, .buffer_size = 10});
	defer p.deinit();

	const i1a = p.acquireLarge() orelse unreachable;
	try t.expectEqual(15, i1a.len);
	const i2a = p.acquireLarge() orelse unreachable;
	try t.expectEqual(15, i2a.len);

	try t.expectEqual(false, i1a.ptr == i2a.ptr);

	try t.expectEqual(null, p.acquireLarge());

	p.releaseLarge(i1a);
	const i1b = p.acquireLarge() orelse unreachable;
	try t.expectEqual(15, i1b.len);
	try t.expectEqual(true, i1a.ptr == i1b.ptr);

	p.releaseLarge(i2a);
	p.releaseLarge(i1b);
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
		var buf = p.acquireLarge() orelse unreachable;
		// no other thread should have set this to 255
		std.debug.assert(buf[0] == 0);

		buf[0] = 255;
		std.time.sleep(random.uintAtMost(u32, 100000));
		buf[0] = 0;
		p.releaseLarge(buf);
	}
}
