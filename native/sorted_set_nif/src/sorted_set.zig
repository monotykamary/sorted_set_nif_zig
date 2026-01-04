const std = @import("std");
const Bucket = @import("bucket.zig").Bucket;
const SupportedTerm = @import("supported_term.zig").SupportedTerm;
const Configuration = @import("configuration.zig").Configuration;

pub const AddResult = union(enum) {
    Added: usize,
    Duplicate: usize,
};

pub const RemoveResult = union(enum) {
    Removed: usize,
    NotFound,
};

pub const FindResult = union(enum) {
    Found: struct {
        bucket_idx: usize,
        inner_idx: usize,
        idx: usize,
    },
    NotFound,
};

pub const AppendBucketResult = enum {
    Ok,
    MaxBucketSizeExceeded,
};

pub const SortedSet = struct {
    configuration: Configuration,
    buckets: std.ArrayList(Bucket),
    count: usize,
    allocator: std.mem.Allocator,

    pub fn empty(allocator: std.mem.Allocator, configuration: Configuration) SortedSet {
        if (configuration.max_bucket_size < 1) {
            @panic("SortedSet max_bucket_size must be greater than 0");
        }

        const buckets = std.ArrayList(Bucket).initCapacity(allocator, configuration.initial_set_capacity) catch unreachable;

        return .{
            .configuration = configuration,
            .buckets = buckets,
            .count = 0,
            .allocator = allocator,
        };
    }

    pub fn new(allocator: std.mem.Allocator, configuration: Configuration) SortedSet {
        var set = SortedSet.empty(allocator, configuration);
        set.buckets.append(allocator, Bucket.init(allocator)) catch unreachable;
        return set;
    }

    pub fn deinit(self: *SortedSet) void {
        for (self.buckets.items) |*bucket| {
            bucket.deinit();
        }
        self.buckets.deinit(self.allocator);
    }

    pub fn appendBucket(self: *SortedSet, items: []SupportedTerm) AppendBucketResult {
        if (self.configuration.max_bucket_size <= items.len) {
            for (items) |*item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items);
            return .MaxBucketSizeExceeded;
        }

        self.count += items.len;
        self.buckets.append(self.allocator, Bucket.fromOwnedSlice(self.allocator, items)) catch unreachable;
        return .Ok;
    }

    pub fn findBucketIndex(self: *const SortedSet, item: *const SupportedTerm) usize {
        var lo: usize = 0;
        var hi: usize = self.buckets.items.len;

        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const ordering = self.buckets.items[mid].itemCompare(item);
            switch (ordering) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }

        const idx = lo;
        if (idx >= self.buckets.items.len) return self.buckets.items.len - 1;
        return idx;
    }

    pub fn findIndex(self: *const SortedSet, item: *const SupportedTerm) FindResult {
        const bucket_idx = self.findBucketIndex(item);
        const bucket = &self.buckets.items[bucket_idx];

        var lo: usize = 0;
        var hi: usize = bucket.data.items.len;

        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const ordering = SupportedTerm.cmp(bucket.data.items[mid], item.*);
            switch (ordering) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    return .{ .Found = .{
                        .bucket_idx = bucket_idx,
                        .inner_idx = mid,
                        .idx = self.effectiveIndex(bucket_idx, mid),
                    } };
                },
            }
        }

        return .NotFound;
    }

    fn effectiveIndex(self: *const SortedSet, bucket: usize, index: usize) usize {
        var result = index;
        var bucket_index: usize = 0;
        while (bucket_index < bucket) : (bucket_index += 1) {
            result += self.buckets.items[bucket_index].len();
        }
        return result;
    }

    fn insertBucket(self: *SortedSet, idx: usize, bucket: Bucket) void {
        if (self.buckets.items.len == self.buckets.capacity) {
            self.buckets.ensureTotalCapacity(self.allocator, self.buckets.items.len + 1) catch unreachable;
        }

        self.buckets.items.len += 1;
        @memmove(self.buckets.items[idx + 1 .. self.buckets.items.len], self.buckets.items[idx .. self.buckets.items.len - 1]);
        self.buckets.items[idx] = bucket;
    }

    pub fn add(self: *SortedSet, item: SupportedTerm) AddResult {
        const bucket_idx = self.findBucketIndex(&item);
        const result = self.buckets.items[bucket_idx].add(item);

        switch (result) {
            .Added => |idx| {
                const effective_idx = self.effectiveIndex(bucket_idx, idx);
                const bucket_len = self.buckets.items[bucket_idx].len();

                if (bucket_len >= self.configuration.max_bucket_size) {
                    const new_bucket = self.buckets.items[bucket_idx].split();
                    self.insertBucket(bucket_idx + 1, new_bucket);
                }

                self.count += 1;
                return .{ .Added = effective_idx };
            },
            .Duplicate => |idx| {
                return .{ .Duplicate = self.effectiveIndex(bucket_idx, idx) };
            },
        }
    }

    pub fn remove(self: *SortedSet, item: *const SupportedTerm) RemoveResult {
        switch (self.findIndex(item)) {
            .Found => |found| {
                if (self.count == 0) {
                    @panic("Just found item in empty set, internal structure error");
                }

                var bucket = &self.buckets.items[found.bucket_idx];
                var removed = bucket.data.orderedRemove(found.inner_idx);
                removed.deinit(self.allocator);

                if (self.buckets.items.len > 1 and bucket.data.items.len == 0) {
                    var empty_bucket = self.buckets.orderedRemove(found.bucket_idx);
                    empty_bucket.deinit();
                }

                self.count -= 1;
                return .{ .Removed = found.idx };
            },
            .NotFound => return .NotFound,
        }
    }

    pub fn at(self: *const SortedSet, index: usize) ?*const SupportedTerm {
        const num_buckets = self.buckets.items.len;
        var bucket_idx: usize = 0;
        var remaining = index;

        while (bucket_idx < num_buckets) : (bucket_idx += 1) {
            const bucket_len = self.buckets.items[bucket_idx].len();
            if (remaining < bucket_len) {
                return &self.buckets.items[bucket_idx].data.items[remaining];
            }
            remaining -= bucket_len;
        }

        return null;
    }

    pub fn slice(self: *const SortedSet, index: usize, amount: usize) []SupportedTerm {
        if (self.buckets.items.len == 0) {
            return self.allocator.alloc(SupportedTerm, 0) catch unreachable;
        }

        var result = std.ArrayList(SupportedTerm).initCapacity(self.allocator, amount) catch unreachable;
        errdefer result.deinit(self.allocator);

        const num_buckets = self.buckets.items.len;
        var bucket_idx: usize = 0;
        var seeking = true;
        var remaining_index = index;
        var remaining_amount = amount;

        while (true) {
            if (seeking) {
                if (remaining_index < self.buckets.items[bucket_idx].len()) {
                    seeking = false;
                } else {
                    remaining_index -= self.buckets.items[bucket_idx].len();
                    bucket_idx += 1;

                    if (bucket_idx >= num_buckets) {
                        return result.toOwnedSlice(self.allocator) catch unreachable;
                    }
                }
            } else {
                const bucket = &self.buckets.items[bucket_idx];
                const items_in_bucket = bucket.len() - remaining_index;

                if (items_in_bucket >= remaining_amount) {
                    var idx = remaining_index;
                    while (idx < remaining_index + remaining_amount) : (idx += 1) {
                        result.append(self.allocator, bucket.data.items[idx].clone(self.allocator) catch unreachable) catch unreachable;
                    }
                    return result.toOwnedSlice(self.allocator) catch unreachable;
                }

                var idx = remaining_index;
                while (idx < bucket.len()) : (idx += 1) {
                    result.append(self.allocator, bucket.data.items[idx].clone(self.allocator) catch unreachable) catch unreachable;
                }

                remaining_amount -= items_in_bucket;
                remaining_index = 0;
                bucket_idx += 1;

                if (bucket_idx >= num_buckets) {
                    return result.toOwnedSlice(self.allocator) catch unreachable;
                }
            }
        }
    }

    pub fn toVec(self: *const SortedSet) []SupportedTerm {
        var result = std.ArrayList(SupportedTerm).initCapacity(self.allocator, self.count) catch unreachable;
        errdefer result.deinit(self.allocator);

        for (self.buckets.items) |bucket| {
            for (bucket.data.items) |item| {
                result.append(self.allocator, item.clone(self.allocator) catch unreachable) catch unreachable;
            }
        }

        return result.toOwnedSlice(self.allocator) catch unreachable;
    }

    pub fn size(self: *const SortedSet) usize {
        return self.count;
    }

    pub fn debug(self: *const SortedSet, allocator: std.mem.Allocator) []u8 {
        return std.fmt.allocPrint(allocator, "{any}", .{self.*}) catch unreachable;
    }
};

const testing = std.testing;

fn makeBitstring(allocator: std.mem.Allocator, value: []const u8) !SupportedTerm {
    const buf = try allocator.alloc(u8, value.len);
    std.mem.copyForwards(u8, buf, value);
    return .{ .Bitstring = .{ .bytes = buf, .len = buf.len } };
}

fn expectTermSlicesEqual(expected: []const SupportedTerm, actual: []const SupportedTerm) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |item, idx| {
        try testing.expect(item.eql(actual[idx]));
    }
}

fn deinitTermSlice(allocator: std.mem.Allocator, slice: []SupportedTerm) void {
    for (slice) |*item| {
        item.deinit(allocator);
    }
    allocator.free(slice);
}

test "sorted_set_sorted" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    var expected: std.ArrayList(SupportedTerm) = .{};
    defer expected.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const item_str = try std.fmt.bufPrint(&buf, "test-item-{d}", .{i});
        const term = try makeBitstring(testing.allocator, item_str);
        try expected.append(testing.allocator, try term.clone(testing.allocator));
        _ = set.add(term);
    }

    std.sort.pdq(SupportedTerm, expected.items, {}, @import("supported_term.zig").lessThan);

    const vec_from_set = set.toVec();
    defer deinitTermSlice(testing.allocator, vec_from_set);

    try expectTermSlicesEqual(expected.items, vec_from_set);
    for (expected.items) |*item| {
        item.deinit(testing.allocator);
    }
}

test "sorted_set_duplicate_item" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    try testing.expectEqual(@as(usize, 0), set.size());

    var item = try makeBitstring(testing.allocator, "test-item");
    switch (set.add(item)) {
        .Added => |idx| try testing.expectEqual(@as(usize, 0), idx),
        .Duplicate => |_| return testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), set.size());

    item = try makeBitstring(testing.allocator, "test-item");
    switch (set.add(item)) {
        .Added => |_| return testing.expect(false),
        .Duplicate => |idx| try testing.expectEqual(@as(usize, 0), idx),
    }

    try testing.expectEqual(@as(usize, 1), set.size());
}

test "sorted_set_retrieving_an_item" {
    var set = SortedSet.new(testing.allocator, Configuration.init(3, 0));
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));

    const item0 = set.at(0).?;
    const item1 = set.at(1).?;
    const item2 = set.at(2).?;

    var expected0 = try makeBitstring(testing.allocator, "aaa");
    defer expected0.deinit(testing.allocator);
    try testing.expect(item0.eql(expected0));

    var expected1 = try makeBitstring(testing.allocator, "bbb");
    defer expected1.deinit(testing.allocator);
    try testing.expect(item1.eql(expected1));

    var expected2 = try makeBitstring(testing.allocator, "ccc");
    defer expected2.deinit(testing.allocator);
    try testing.expect(item2.eql(expected2));

    try testing.expect(set.at(3) == null);
}

test "sorted_set_removing_a_present_item" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));

    const before = set.toVec();
    defer deinitTermSlice(testing.allocator, before);

    var expected_before: std.ArrayList(SupportedTerm) = .{};
    defer expected_before.deinit(testing.allocator);
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "aaa"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "bbb"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "ccc"));

    try expectTermSlicesEqual(expected_before.items, before);
    for (expected_before.items) |*item| item.deinit(testing.allocator);

    var item = try makeBitstring(testing.allocator, "bbb");
    defer item.deinit(testing.allocator);

    switch (set.remove(&item)) {
        .Removed => |idx| try testing.expectEqual(@as(usize, 1), idx),
        .NotFound => return testing.expect(false),
    }

    const after = set.toVec();
    defer deinitTermSlice(testing.allocator, after);

    var expected_after: std.ArrayList(SupportedTerm) = .{};
    defer expected_after.deinit(testing.allocator);
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "aaa"));
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "ccc"));

    try expectTermSlicesEqual(expected_after.items, after);
    for (expected_after.items) |*term| term.deinit(testing.allocator);
}

test "sorted_set_removing_a_not_found_item" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));

    const before = set.toVec();
    defer deinitTermSlice(testing.allocator, before);

    var expected_before: std.ArrayList(SupportedTerm) = .{};
    defer expected_before.deinit(testing.allocator);
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "aaa"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "bbb"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "ccc"));

    try expectTermSlicesEqual(expected_before.items, before);
    for (expected_before.items) |*term| term.deinit(testing.allocator);

    var item = try makeBitstring(testing.allocator, "zzz");
    defer item.deinit(testing.allocator);

    switch (set.remove(&item)) {
        .Removed => return testing.expect(false),
        .NotFound => {},
    }

    const after = set.toVec();
    defer deinitTermSlice(testing.allocator, after);

    var expected_after: std.ArrayList(SupportedTerm) = .{};
    defer expected_after.deinit(testing.allocator);
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "aaa"));
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "bbb"));
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "ccc"));

    try expectTermSlicesEqual(expected_after.items, after);
    for (expected_after.items) |*term| term.deinit(testing.allocator);
}

test "sorted_set_removing_from_non_leading_bucket" {
    var set = SortedSet.new(testing.allocator, Configuration.init(3, 0));
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));
    _ = set.add(try makeBitstring(testing.allocator, "ddd"));
    _ = set.add(try makeBitstring(testing.allocator, "eee"));

    const before = set.toVec();
    defer deinitTermSlice(testing.allocator, before);

    var expected_before: std.ArrayList(SupportedTerm) = .{};
    defer expected_before.deinit(testing.allocator);
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "aaa"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "bbb"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "ccc"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "ddd"));
    try expected_before.append(testing.allocator, try makeBitstring(testing.allocator, "eee"));

    try expectTermSlicesEqual(expected_before.items, before);
    for (expected_before.items) |*term| term.deinit(testing.allocator);

    var item = try makeBitstring(testing.allocator, "ddd");
    defer item.deinit(testing.allocator);

    switch (set.remove(&item)) {
        .Removed => |idx| try testing.expectEqual(@as(usize, 3), idx),
        .NotFound => return testing.expect(false),
    }

    const after = set.toVec();
    defer deinitTermSlice(testing.allocator, after);

    var expected_after: std.ArrayList(SupportedTerm) = .{};
    defer expected_after.deinit(testing.allocator);
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "aaa"));
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "bbb"));
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "ccc"));
    try expected_after.append(testing.allocator, try makeBitstring(testing.allocator, "eee"));

    try expectTermSlicesEqual(expected_after.items, after);
    for (expected_after.items) |*term| term.deinit(testing.allocator);
}

test "sorted_set_find_bucket_in_empty_set" {
    var set = SortedSet.new(testing.allocator, Configuration.init(5, 0));
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 10 };
    try testing.expectEqual(@as(usize, 0), set.findBucketIndex(&item));
}

test "sorted_set_removing_decrements_the_size_on_successful_removal" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));
    _ = set.add(try makeBitstring(testing.allocator, "ddd"));
    _ = set.add(try makeBitstring(testing.allocator, "eee"));

    try testing.expectEqual(@as(usize, 5), set.size());

    {
        var item = try makeBitstring(testing.allocator, "ccc");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 4), set.size());

    {
        var item = try makeBitstring(testing.allocator, "eee");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 3), set.size());

    {
        var item = try makeBitstring(testing.allocator, "aaa");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 2), set.size());

    {
        var item = try makeBitstring(testing.allocator, "ddd");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 1), set.size());

    {
        var item = try makeBitstring(testing.allocator, "bbb");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 0), set.size());
}

test "sorted_set_multiple_removes_of_the_same_value_do_not_decrement_size" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));
    _ = set.add(try makeBitstring(testing.allocator, "ddd"));
    _ = set.add(try makeBitstring(testing.allocator, "eee"));

    try testing.expectEqual(@as(usize, 5), set.size());

    {
        var item = try makeBitstring(testing.allocator, "ccc");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 4), set.size());

    {
        var item = try makeBitstring(testing.allocator, "ccc");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 4), set.size());

    {
        var item = try makeBitstring(testing.allocator, "ccc");
        defer item.deinit(testing.allocator);
        _ = set.remove(&item);
    }
    try testing.expectEqual(@as(usize, 4), set.size());
}

test "sorted_set_removing_item_not_present_does_nothing" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    _ = set.add(try makeBitstring(testing.allocator, "aaa"));
    _ = set.add(try makeBitstring(testing.allocator, "bbb"));
    _ = set.add(try makeBitstring(testing.allocator, "ccc"));
    _ = set.add(try makeBitstring(testing.allocator, "ddd"));
    _ = set.add(try makeBitstring(testing.allocator, "eee"));

    try testing.expectEqual(@as(usize, 5), set.size());

    const before = set.toVec();
    defer deinitTermSlice(testing.allocator, before);

    var item = try makeBitstring(testing.allocator, "xxx");
    defer item.deinit(testing.allocator);
    _ = set.remove(&item);

    try testing.expectEqual(@as(usize, 5), set.size());

    const after = set.toVec();
    defer deinitTermSlice(testing.allocator, after);

    try expectTermSlicesEqual(before, after);
}

fn buildIntegerSet(max_bucket_size: usize, values: []const i64) SortedSet {
    var set = SortedSet.new(testing.allocator, Configuration.init(max_bucket_size, 0));
    for (values) |value| {
        _ = set.add(.{ .Integer = value });
    }
    return set;
}

test "sorted_set_find_bucket_when_less_than_first_item_in_set" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 0 };
    try testing.expectEqual(@as(usize, 0), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_equal_to_first_item_in_set" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 2 };
    try testing.expectEqual(@as(usize, 0), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_in_first_bucket_unique" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 3 };
    try testing.expectEqual(@as(usize, 0), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_in_first_bucket_duplicate" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 4 };
    try testing.expectEqual(@as(usize, 0), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_between_buckets_selects_the_right_hand_bucket" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 5 };
    try testing.expectEqual(@as(usize, 1), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_in_interior_bucket_unique" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 7 };
    try testing.expectEqual(@as(usize, 1), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_in_interior_bucket_duplicate" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 8 };
    try testing.expectEqual(@as(usize, 1), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_in_last_bucket_unique" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 15 };
    try testing.expectEqual(@as(usize, 3), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_in_last_bucket_duplicate" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 16 };
    try testing.expectEqual(@as(usize, 3), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_equal_to_last_item_in_set" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 20 };
    try testing.expectEqual(@as(usize, 3), set.findBucketIndex(&item));
}

test "sorted_set_find_bucket_when_greater_than_last_item_in_set" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const item = SupportedTerm{ .Integer = 21 };
    try testing.expectEqual(@as(usize, 3), set.findBucketIndex(&item));
}

test "sorted_set_slice_starting_at_0_amount_0" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(0, 0);
    defer deinitTermSlice(testing.allocator, slice);

    try testing.expectEqual(@as(usize, 0), slice.len);
}

test "sorted_set_slice_new_set" {
    var set = SortedSet.new(testing.allocator, Configuration.default());
    defer set.deinit();

    const slice = set.slice(0, 100);
    defer deinitTermSlice(testing.allocator, slice);

    try testing.expectEqual(@as(usize, 0), slice.len);
}

test "sorted_set_slice_empty_set" {
    var set = SortedSet.empty(testing.allocator, Configuration.default());
    defer set.deinit();

    const slice = set.slice(0, 100);
    defer deinitTermSlice(testing.allocator, slice);

    try testing.expectEqual(@as(usize, 0), slice.len);
}

test "sorted_set_slice_single_bucket_satisfiable" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(1, 1);
    defer deinitTermSlice(testing.allocator, slice);

    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expect(slice[0].eql(.{ .Integer = 4 }));
}

test "sorted_set_slice_multi_cell_satisfiable" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(1, 4);
    defer deinitTermSlice(testing.allocator, slice);

    var expected = [_]SupportedTerm{
        .{ .Integer = 4 },
        .{ .Integer = 6 },
        .{ .Integer = 8 },
        .{ .Integer = 10 },
    };

    try expectTermSlicesEqual(expected[0..], slice);
}

test "sorted_set_slice_exactly_exhausted_from_non_terminal" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(3, 6);
    defer deinitTermSlice(testing.allocator, slice);

    var expected = [_]SupportedTerm{
        .{ .Integer = 8 },
        .{ .Integer = 10 },
        .{ .Integer = 12 },
        .{ .Integer = 14 },
        .{ .Integer = 16 },
        .{ .Integer = 18 },
    };

    try expectTermSlicesEqual(expected[0..], slice);
}

test "sorted_set_slice_over_exhausted_from_non_terminal" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(3, 10);
    defer deinitTermSlice(testing.allocator, slice);

    var expected = [_]SupportedTerm{
        .{ .Integer = 8 },
        .{ .Integer = 10 },
        .{ .Integer = 12 },
        .{ .Integer = 14 },
        .{ .Integer = 16 },
        .{ .Integer = 18 },
    };

    try expectTermSlicesEqual(expected[0..], slice);
}

test "sorted_set_slice_exactly_exhausted_from_terminal" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(7, 2);
    defer deinitTermSlice(testing.allocator, slice);

    var expected = [_]SupportedTerm{
        .{ .Integer = 16 },
        .{ .Integer = 18 },
    };

    try expectTermSlicesEqual(expected[0..], slice);
}

test "sorted_set_slice_over_exhausted_from_terminal" {
    var set = buildIntegerSet(5, &[_]i64{ 2, 4, 6, 8, 10, 12, 14, 16, 18 });
    defer set.deinit();

    const slice = set.slice(7, 10);
    defer deinitTermSlice(testing.allocator, slice);

    var expected = [_]SupportedTerm{
        .{ .Integer = 16 },
        .{ .Integer = 18 },
    };

    try expectTermSlicesEqual(expected[0..], slice);
}
