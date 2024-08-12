const std = @import("std");

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectFmt = std.testing.expectFmt;
pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const expectSuffix = std.testing.expectStringEndsWith;
pub const expectPrefix = std.testing.expectStringStartsWith;

pub var out_mutex = std.Thread.Mutex{};

pub fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return std.Random.DefaultPrng.init(seed);
}

pub fn timestamp() i64 {
    return 9999999999999;
}

pub const is_test = @import("builtin").is_test;

pub const JsonComparer = struct {
    _arena: std.heap.ArenaAllocator,

    const Diff = struct {
        err: []const u8,
        path: []const u8,
        a: []const u8,
        b: []const u8,
    };
    const Diffs = std.ArrayList(Diff);

    pub fn init() JsonComparer {
        return .{
            ._arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: JsonComparer) void {
        self._arena.deinit();
    }

    // We compare by getting the string representation of a and b
    // and then parsing it into a std.json.ValueTree, which we can compare
    // Either a or b might already be serialized JSON string.
    pub fn compare(self: *JsonComparer, a: anytype, b: anytype) !Diffs {
        const aa = self._arena.allocator();
        var a_bytes: []const u8 = undefined;
        if (@TypeOf(a) != []const u8) {
            // a isn't a string, let's serialize it
            a_bytes = try self.stringify(a);
        } else {
            a_bytes = a;
        }

        var b_bytes: []const u8 = undefined;
        if (@TypeOf(b) != []const u8) {
            // b isn't a string, let's serialize it
            b_bytes = try self.stringify(b);
        } else {
            b_bytes = b;
        }

        const a_value = try std.json.parseFromSliceLeaky(std.json.Value, aa, a_bytes, .{});
        const b_value = try std.json.parseFromSliceLeaky(std.json.Value, aa, b_bytes, .{});

        var diffs = Diffs.init(aa);
        var path = std.ArrayList([]const u8).init(aa);
        try self.compareValue(a_value, b_value, &diffs, &path);
        return diffs;
    }

    fn compareValue(self: *JsonComparer, a: std.json.Value, b: std.json.Value, diffs: *Diffs, path: *std.ArrayList([]const u8)) !void {
        const aa = self._arena.allocator();

        if (!std.mem.eql(u8, @tagName(a), @tagName(b))) {
            diffs.append(self.diff("types don't match", path, @tagName(a), @tagName(b))) catch unreachable;
            return;
        }

        switch (a) {
            .null => {},
            .bool => {
                if (a.bool != b.bool) {
                    diffs.append(self.diff("not equal", path, self.format(a.bool), self.format(b.bool))) catch unreachable;
                }
            },
            .integer => {
                if (a.integer != b.integer) {
                    diffs.append(self.diff("not equal", path, self.format(a.integer), self.format(b.integer))) catch unreachable;
                }
            },
            .float => {
                if (a.float != b.float) {
                    diffs.append(self.diff("not equal", path, self.format(a.float), self.format(b.float))) catch unreachable;
                }
            },
            .number_string => {
                if (!std.mem.eql(u8, a.number_string, b.number_string)) {
                    diffs.append(self.diff("not equal", path, a.number_string, b.number_string)) catch unreachable;
                }
            },
            .string => {
                if (!std.mem.eql(u8, a.string, b.string)) {
                    diffs.append(self.diff("not equal", path, a.string, b.string)) catch unreachable;
                }
            },
            .array => {
                const a_len = a.array.items.len;
                const b_len = b.array.items.len;
                if (a_len != b_len) {
                    diffs.append(self.diff("array length", path, self.format(a_len), self.format(b_len))) catch unreachable;
                    return;
                }
                for (a.array.items, b.array.items, 0..) |a_item, b_item, i| {
                    try path.append(try std.fmt.allocPrint(aa, "{d}", .{i}));
                    try self.compareValue(a_item, b_item, diffs, path);
                    _ = path.pop();
                }
            },
            .object => {
                var it = a.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    try path.append(key);
                    if (b.object.get(key)) |b_item| {
                        try self.compareValue(entry.value_ptr.*, b_item, diffs, path);
                    } else {
                        diffs.append(self.diff("field missing", path, key, "")) catch unreachable;
                    }
                    _ = path.pop();
                }
            },
        }
    }

    fn diff(self: *JsonComparer, err: []const u8, path: *std.ArrayList([]const u8), a_rep: []const u8, b_rep: []const u8) Diff {
        const full_path = std.mem.join(self._arena.allocator(), ".", path.items) catch unreachable;
        return .{
            .a = a_rep,
            .b = b_rep,
            .err = err,
            .path = full_path,
        };
    }

    fn stringify(self: *JsonComparer, value: anytype) ![]const u8 {
        var arr = std.ArrayList(u8).init(self._arena.allocator());
        try std.json.stringify(value, .{}, arr.writer());
        return arr.items;
    }

    fn format(self: *JsonComparer, value: anytype) []const u8 {
        return std.fmt.allocPrint(self._arena.allocator(), "{}", .{value}) catch unreachable;
    }
};
