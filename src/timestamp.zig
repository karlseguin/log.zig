const std = @import("std");
const t = @import("t.zig");

const Format = @import("config.zig").Config.Timestamp;

const NUMBER_LEN = "9999999999999".len;
const ISO_LEN = "9999-99-99T99:99:99.999999Z".len;
const SQL_LEN = "9999-99-99 99:99:99.999999".len;

// The number of bytes that write() writes for the given format
pub fn len(format: Format) usize {
    return switch (format) {
        .number => NUMBER_LEN,
        .iso => ISO_LEN,
        .sql => SQL_LEN,
    };
}

fn nowMilliseconds(io: std.Io) i64 {
    if (t.is_test) return t.timestamp();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

fn nowMicroseconds(io: std.Io) i64 {
    if (t.is_test) return t.timestamp() * std.time.us_per_ms;
    return std.Io.Clock.real.now(io).toMicroseconds();
}

// Writes the current time (UTC) into buf, which must be at least len(format)
// bytes long. Returns the number of bytes written, which is len(format).
pub fn write(io: std.Io, buf: []u8, format: Format) usize {
    switch (format) {
        .number => _ = std.fmt.printInt(buf, nowMilliseconds(io), 10, .lower, .{}),
        .iso, .sql => {
            // a clock set before 1970 is logged as 1970
            const micros: u64 = @intCast(@max(0, nowMicroseconds(io)));
            const es = std.time.epoch.EpochSeconds{ .secs = micros / std.time.us_per_s };
            const day_secs = es.getDaySeconds();
            const year_day = es.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();

            // iso and sql only differ by the date/time separator and iso's trailing Z
            _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
                year_day.year,
                month_day.month.numeric(),
                @as(u8, month_day.day_index) + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
                micros % std.time.us_per_s,
            }) catch unreachable;

            if (format == .iso) {
                buf[10] = 'T';
                buf[SQL_LEN] = 'Z';
            }
        },
    }
    return len(format);
}

test "timestamp: write" {
    var buf: [ISO_LEN]u8 = undefined;

    try t.expectEqual(13, write(t.io, &buf, .number));
    try t.expectString("9999999999999", buf[0..13]);

    try t.expectEqual(27, write(t.io, &buf, .iso));
    try t.expectString("2286-11-20T17:46:39.999000Z", buf[0..27]);

    try t.expectEqual(26, write(t.io, &buf, .sql));
    try t.expectString("2286-11-20 17:46:39.999000", buf[0..26]);
}
