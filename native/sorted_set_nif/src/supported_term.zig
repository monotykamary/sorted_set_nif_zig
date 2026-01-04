const std = @import("std");

pub const ByteString = struct {
    bytes: []u8,
    len: usize,

    pub fn slice(self: ByteString) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const SupportedTerm = union(enum) {
    Integer: i64,
    Atom: ByteString,
    Tuple: []SupportedTerm,
    List: []SupportedTerm,
    Bitstring: ByteString,

    pub fn deinit(self: *SupportedTerm, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Integer => {},
            .Atom => |value| allocator.free(value.bytes),
            .Bitstring => |value| allocator.free(value.bytes),
            .Tuple => |items| {
                for (items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            },
            .List => |items| {
                for (items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            },
        }
    }

    pub fn clone(self: SupportedTerm, allocator: std.mem.Allocator) std.mem.Allocator.Error!SupportedTerm {
        return switch (self) {
            .Integer => |value| .{ .Integer = value },
            .Atom => |value| .{ .Atom = try cloneBytes(value, allocator) },
            .Bitstring => |value| .{ .Bitstring = try cloneBytes(value, allocator) },
            .Tuple => |items| .{ .Tuple = try cloneItems(items, allocator) },
            .List => |items| .{ .List = try cloneItems(items, allocator) },
        };
    }

    pub fn eql(self: SupportedTerm, other: SupportedTerm) bool {
        return cmp(self, other) == .eq;
    }

    pub fn cmp(self: SupportedTerm, other: SupportedTerm) std.math.Order {
        const self_order = typeOrder(self);
        const other_order = typeOrder(other);

        if (self_order < other_order) return .lt;
        if (self_order > other_order) return .gt;

        return switch (self) {
            .Integer => |lhs| switch (other) {
                .Integer => |rhs| std.math.order(lhs, rhs),
                else => unreachable,
            },
            .Atom => |lhs| switch (other) {
                .Atom => |rhs| std.mem.order(u8, lhs.slice(), rhs.slice()),
                else => unreachable,
            },
            .Tuple => |lhs| switch (other) {
                .Tuple => |rhs| compareTuple(lhs, rhs),
                else => unreachable,
            },
            .List => |lhs| switch (other) {
                .List => |rhs| compareList(lhs, rhs),
                else => unreachable,
            },
            .Bitstring => |lhs| switch (other) {
                .Bitstring => |rhs| std.mem.order(u8, lhs.slice(), rhs.slice()),
                else => unreachable,
            },
        };
    }

    fn typeOrder(term: SupportedTerm) u8 {
        return switch (term) {
            .Integer => 0,
            .Atom => 1,
            .Tuple => 2,
            .List => 3,
            .Bitstring => 4,
        };
    }

    fn compareTuple(lhs: []SupportedTerm, rhs: []SupportedTerm) std.math.Order {
        if (lhs.len != rhs.len) {
            return std.math.order(lhs.len, rhs.len);
        }

        var idx: usize = 0;
        while (idx < lhs.len) : (idx += 1) {
            const ordering = cmp(lhs[idx], rhs[idx]);
            if (ordering != .eq) return ordering;
        }

        return .eq;
    }

    fn compareList(lhs: []SupportedTerm, rhs: []SupportedTerm) std.math.Order {
        const max_common = @min(lhs.len, rhs.len);
        var idx: usize = 0;

        while (idx < max_common) : (idx += 1) {
            const ordering = cmp(lhs[idx], rhs[idx]);
            if (ordering != .eq) return ordering;
        }

        return std.math.order(lhs.len, rhs.len);
    }

    fn cloneBytes(value: ByteString, allocator: std.mem.Allocator) std.mem.Allocator.Error!ByteString {
        const result = try allocator.alloc(u8, value.bytes.len);
        std.mem.copyForwards(u8, result, value.bytes);
        return .{ .bytes = result, .len = value.len };
    }

    fn cloneItems(items: []SupportedTerm, allocator: std.mem.Allocator) std.mem.Allocator.Error![]SupportedTerm {
        const result = try allocator.alloc(SupportedTerm, items.len);
        var idx: usize = 0;
        errdefer {
            while (idx > 0) {
                idx -= 1;
                result[idx].deinit(allocator);
            }
            allocator.free(result);
        }

        for (items) |item| {
            result[idx] = try item.clone(allocator);
            idx += 1;
        }

        return result;
    }
};

pub fn lessThan(_: void, lhs: SupportedTerm, rhs: SupportedTerm) bool {
    return SupportedTerm.cmp(lhs, rhs) == .lt;
}
