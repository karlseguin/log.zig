const std = @import("std");
const t = @import("t.zig");

pub const Format = enum {
    iso,
    sql,
};

pub fn nowMilliseconds(io: std.Io) i64 {
    if (t.is_test) return t.timestamp();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

pub fn nowFormatted(io: std.Io, allocator: std.mem.Allocator, format: Format) ![]const u8 {
    const timestamp = std.Io.Clock.real.now(io);
    const unix_sec = @divTrunc(timestamp.toNanoseconds(), std.time.ns_per_s);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_sec) };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}{s}{d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        if (format == .iso) "T" else " ",
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}
