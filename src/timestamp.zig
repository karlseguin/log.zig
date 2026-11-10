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

pub fn nowFormatted(io: std.Io, format: Format) ![]const u8 {
    const timestamp = std.Io.Clock.real.now(io);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp.toSeconds()) };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    if (format == .iso) {
        var buffer: [20]u8 = undefined;
        return try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        });
    }
    var buffer: [19]u8 = undefined;
    return try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}
