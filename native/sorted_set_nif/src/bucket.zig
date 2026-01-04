const std = @import("std");
const SupportedTerm = @import("supported_term.zig").SupportedTerm;

pub const AddResult = union(enum) {
    Added: usize,
    Duplicate: usize,
};

pub const Bucket = struct {
    data: std.ArrayList(SupportedTerm),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bucket {
        return .{ .data = .{}, .allocator = allocator };
    }

    pub fn fromOwnedSlice(allocator: std.mem.Allocator, items: []SupportedTerm) Bucket {
        return .{ .data = std.ArrayList(SupportedTerm).fromOwnedSlice(items), .allocator = allocator };
    }

    pub fn deinit(self: *Bucket) void {
        for (self.data.items) |*item| {
            item.deinit(self.allocator);
        }
        self.data.deinit(self.allocator);
    }

    pub fn len(self: *const Bucket) usize {
        return self.data.items.len;
    }

    pub fn add(self: *Bucket, item: SupportedTerm) AddResult {
        var owned_item = item;
        var lo: usize = 0;
        var hi: usize = self.data.items.len;

        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const ordering = SupportedTerm.cmp(self.data.items[mid], owned_item);
            switch (ordering) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    owned_item.deinit(self.allocator);
                    return .{ .Duplicate = mid };
                },
            }
        }

        self.data.insert(self.allocator, lo, owned_item) catch unreachable;
        return .{ .Added = lo };
    }

    pub fn split(self: *Bucket) Bucket {
        const curr_len = self.data.items.len;
        const at = curr_len / 2;
        const other_len = curr_len - at;
        const other_capacity = self.data.capacity;

        var other = Bucket.init(self.allocator);
        if (other_capacity > 0) {
            other.data.ensureTotalCapacityPrecise(self.allocator, other_capacity) catch unreachable;
            const other_buf = other.data.allocatedSlice();
            if (other_len > 0) {
                std.mem.copyForwards(SupportedTerm, other_buf[0..other_len], self.data.items[at..]);
            }
            other.data.items = other_buf[0..other_len];
        }

        self.data.items = self.data.items[0..at];
        return other;
    }

    pub fn itemCompare(self: *const Bucket, item: *const SupportedTerm) std.math.Order {
        if (self.data.items.len == 0) return .eq;

        const first = self.data.items[0];
        const last = self.data.items[self.data.items.len - 1];

        if (SupportedTerm.cmp(item.*, first) == .lt) {
            return .gt;
        }

        if (SupportedTerm.cmp(last, item.*) == .lt) {
            return .lt;
        }

        return .eq;
    }
};

const testing = std.testing;

fn allocItems(allocator: std.mem.Allocator, values: []const i64) ![]SupportedTerm {
    const items = try allocator.alloc(SupportedTerm, values.len);
    for (values, 0..) |value, idx| {
        items[idx] = .{ .Integer = value };
    }
    return items;
}

test "item_compare_empty_bucket" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    const item = SupportedTerm{ .Integer = 5 };
    try testing.expectEqual(std.math.Order.eq, bucket.itemCompare(&item));
}

test "item_compare_when_less_than_first_item" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    _ = bucket.add(.{ .Integer = 5 });

    const item = SupportedTerm{ .Integer = 3 };
    try testing.expectEqual(std.math.Order.gt, bucket.itemCompare(&item));
}

test "item_compare_when_equal_to_first_item" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    _ = bucket.add(.{ .Integer = 5 });

    const item = SupportedTerm{ .Integer = 5 };
    try testing.expectEqual(std.math.Order.eq, bucket.itemCompare(&item));
}

test "item_compare_when_greater_than_last_item" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    _ = bucket.add(.{ .Integer = 1 });
    _ = bucket.add(.{ .Integer = 2 });
    _ = bucket.add(.{ .Integer = 3 });

    const item = SupportedTerm{ .Integer = 5 };
    try testing.expectEqual(std.math.Order.lt, bucket.itemCompare(&item));
}

test "item_compare_when_equal_to_last_item" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    _ = bucket.add(.{ .Integer = 1 });
    _ = bucket.add(.{ .Integer = 2 });
    _ = bucket.add(.{ .Integer = 3 });

    const item = SupportedTerm{ .Integer = 3 };
    try testing.expectEqual(std.math.Order.eq, bucket.itemCompare(&item));
}

test "item_between_first_and_last_duplicate" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    _ = bucket.add(.{ .Integer = 1 });
    _ = bucket.add(.{ .Integer = 2 });
    _ = bucket.add(.{ .Integer = 3 });

    const item = SupportedTerm{ .Integer = 1 };
    try testing.expectEqual(std.math.Order.eq, bucket.itemCompare(&item));
}

test "item_between_first_and_last_unique" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    _ = bucket.add(.{ .Integer = 2 });
    _ = bucket.add(.{ .Integer = 4 });
    _ = bucket.add(.{ .Integer = 6 });

    const item = SupportedTerm{ .Integer = 3 };
    try testing.expectEqual(std.math.Order.eq, bucket.itemCompare(&item));
}

test "split_bucket_with_no_items" {
    var bucket = Bucket.init(testing.allocator);
    defer bucket.deinit();

    try testing.expectEqual(@as(usize, 0), bucket.data.items.len);
    try testing.expectEqual(@as(usize, 0), bucket.data.capacity);

    var other = bucket.split();
    defer other.deinit();

    try testing.expectEqual(@as(usize, 0), bucket.data.items.len);
    try testing.expectEqual(@as(usize, 0), bucket.data.capacity);

    try testing.expectEqual(@as(usize, 0), other.data.items.len);
    try testing.expectEqual(@as(usize, 0), other.data.capacity);
}

test "split_bucket_with_odd_number_of_items" {
    const values = [_]i64{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const items = try allocItems(testing.allocator, values[0..]);
    var bucket = Bucket.fromOwnedSlice(testing.allocator, items);
    defer bucket.deinit();

    try testing.expectEqual(@as(usize, 9), bucket.data.items.len);
    try testing.expectEqual(@as(usize, 9), bucket.data.capacity);

    var other = bucket.split();
    defer other.deinit();

    try testing.expectEqual(@as(usize, 4), bucket.data.items.len);
    try testing.expectEqual(@as(usize, 9), bucket.data.capacity);

    try testing.expectEqual(@as(usize, 5), other.data.items.len);
    try testing.expectEqual(@as(usize, 9), other.data.capacity);
}

test "split_bucket_with_even_number_of_items" {
    const values = [_]i64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const items = try allocItems(testing.allocator, values[0..]);
    var bucket = Bucket.fromOwnedSlice(testing.allocator, items);
    defer bucket.deinit();

    try testing.expectEqual(@as(usize, 10), bucket.data.items.len);
    try testing.expectEqual(@as(usize, 10), bucket.data.capacity);

    var other = bucket.split();
    defer other.deinit();

    try testing.expectEqual(@as(usize, 5), bucket.data.items.len);
    try testing.expectEqual(@as(usize, 10), bucket.data.capacity);

    try testing.expectEqual(@as(usize, 5), other.data.items.len);
    try testing.expectEqual(@as(usize, 10), other.data.capacity);
}
