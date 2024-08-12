const m = @import("metrics");

// This is an advanced usage of metrics.zig, largely done because we aren't
// using any vectored metrics and thus can do everything at comptime.
var metrics = Metrics{
    .no_space = m.Counter(u64).Impl.init("logz_no_space", .{}),
    .pool_empty = m.Counter(usize).Impl.init("logz_pool_empty", .{}),
    .large_buffer_empty = m.Counter(usize).Impl.init("logz_large_buffer_empty", .{}),
    .large_buffer_acquire = m.Counter(usize).Impl.init("logz_large_buffer_acquire", .{}),
};

const Metrics = struct {
    no_space: m.Counter(u64).Impl,
    pool_empty: m.Counter(usize).Impl,
    large_buffer_empty: m.Counter(usize).Impl,
    large_buffer_acquire: m.Counter(usize).Impl,
};

pub fn write(writer: anytype) !void {
    try metrics.no_space.write(writer);
    try metrics.pool_empty.write(writer);
    try metrics.large_buffer_empty.write(writer);
    try metrics.large_buffer_acquire.write(writer);
}

pub fn noSpace(size: usize) void {
    metrics.pool_empty.incrBy(size);
}

pub fn poolEmpty() void {
    metrics.pool_empty.incr();
}

pub fn largeBufferEmpty() void {
    metrics.large_buffer_empty.incr();
}

pub fn largeBufferAcquire() void {
    metrics.large_buffer_acquire.incr();
}
