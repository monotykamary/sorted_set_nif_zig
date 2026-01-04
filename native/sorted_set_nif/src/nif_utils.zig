const std = @import("std");
const SupportedTerm = @import("supported_term.zig").SupportedTerm;

pub const c = @cImport({
    @cInclude("erl_nif.h");
});

pub const Term = c.ERL_NIF_TERM;

pub const Env = struct {
    raw: *c.ErlNifEnv,
};

pub const Atom = struct {
    name: []const u8,
};

pub fn atom(name: []const u8) Atom {
    return .{ .name = name };
}

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Atom,

        pub const is_nif_result = true;
    };
}

pub const DecodeError = error{ BadArg, UnsupportedType, BadReference };

pub const BeamAllocator = struct {
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator() std.mem.Allocator {
        return .{ .ptr = @ptrFromInt(1), .vtable = &vtable };
    }

    fn alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        if (len == 0) return null;
        const ptr = c.enif_alloc(len) orelse return null;
        return @ptrCast(ptr);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        if (new_len == 0) return null;
        const ptr = c.enif_realloc(memory.ptr, new_len) orelse return null;
        return @ptrCast(ptr);
    }

    fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        c.enif_free(memory.ptr);
    }
};

pub const beam_allocator = BeamAllocator.allocator();

pub fn wrap(comptime func: anytype) *const fn (?*c.ErlNifEnv, c_int, [*c]const Term) callconv(.c) Term {
    const FnType = @TypeOf(func);
    const fn_info = @typeInfo(FnType).@"fn";
    const param_infos = fn_info.params;
    comptime var param_types: [param_infos.len]type = undefined;
    inline for (param_infos, 0..) |param, idx| {
        if (param.type) |ty| {
            param_types[idx] = ty;
        } else {
            if (idx == 0) {
                param_types[idx] = Env;
            } else {
                @compileError("nif.wrap only supports `anytype` for the env parameter");
            }
        }
    }

    const ArgsTuple = std.meta.Tuple(&param_types);
    const arg_fields = @typeInfo(ArgsTuple).@"struct".fields;

    const expects_env = arg_fields.len > 0 and isEnvType(arg_fields[0].type);
    const expected_arity: usize = if (expects_env) arg_fields.len - 1 else arg_fields.len;

    return struct {
        fn wrapped(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const Term) callconv(.c) Term {
            const env_ptr = env orelse return @as(Term, 0);

            if (@as(usize, @intCast(argc)) != expected_arity) {
                return c.enif_make_badarg(env_ptr);
            }

            var args: ArgsTuple = undefined;
            var env_wrapper = Env{ .raw = env_ptr };

            inline for (arg_fields, 0..) |field, field_idx| {
                if (expects_env and field_idx == 0) {
                    if (field.type == Env) {
                        @field(args, field.name) = env_wrapper;
                    } else if (field.type == *Env) {
                        @field(args, field.name) = &env_wrapper;
                    } else {
                        @field(args, field.name) = env_ptr;
                    }
                } else {
                    const argv_index = if (expects_env) field_idx - 1 else field_idx;
                    const term = argv[argv_index];
                    const decoded = decodeArg(field.type, env_ptr, term, beam_allocator) catch |err| {
                        return decodeErrorToTerm(env_ptr, err);
                    };
                    @field(args, field.name) = decoded;
                }
            }

            var arena = std.heap.ArenaAllocator.init(beam_allocator);
            defer arena.deinit();
            const temp_allocator = arena.allocator();

            if (@typeInfo(fn_info.return_type.?) == .error_union) {
                const value = @call(.auto, func, args) catch {
                    return c.enif_make_badarg(env_ptr);
                };
                const term = encodeResult(env_ptr, value, temp_allocator);
                cleanupResult(value, beam_allocator);
                return term;
            }

            const value = @call(.auto, func, args);
            const term = encodeResult(env_ptr, value, temp_allocator);
            cleanupResult(value, beam_allocator);
            return term;
        }
    }.wrapped;
}

fn isEnvType(comptime T: type) bool {
    return T == Env or T == *Env or T == *c.ErlNifEnv;
}

fn decodeErrorToTerm(env: *c.ErlNifEnv, err: DecodeError) Term {
    return switch (err) {
        error.BadArg => c.enif_make_badarg(env),
        error.UnsupportedType => makeError(env, atom("unsupported_type")),
        error.BadReference => makeError(env, atom("bad_reference")),
    };
}

pub fn makeAtom(env: *c.ErlNifEnv, name: []const u8) Term {
    return c.enif_make_atom_len(env, name.ptr, name.len);
}

pub fn makeTuple2(env: *c.ErlNifEnv, a: Term, b: Term) Term {
    return c.enif_make_tuple2(env, a, b);
}

pub fn makeTuple3(env: *c.ErlNifEnv, a: Term, b: Term, c_term: Term) Term {
    return c.enif_make_tuple3(env, a, b, c_term);
}

pub fn makeOk(env: *c.ErlNifEnv, value: anytype, allocator: std.mem.Allocator) Term {
    return makeTuple2(env, makeAtom(env, "ok"), encodeValue(env, value, allocator));
}

pub fn makeError(env: *c.ErlNifEnv, err_atom: Atom) Term {
    return makeTuple2(env, makeAtom(env, "error"), makeAtom(env, err_atom.name));
}

fn encodeResult(env: *c.ErlNifEnv, value: anytype, allocator: std.mem.Allocator) Term {
    const T = @TypeOf(value);
    if (@hasDecl(T, "is_nif_result")) {
        return switch (value) {
            .ok => |ok_value| makeOk(env, ok_value, allocator),
            .err => |err_atom| makeError(env, err_atom),
        };
    }

    return encodeValue(env, value, allocator);
}

fn cleanupResult(value: anytype, allocator: std.mem.Allocator) void {
    const T = @TypeOf(value);
    if (@hasDecl(T, "is_nif_result")) {
        switch (value) {
            .ok => |ok_value| cleanupValue(ok_value, allocator),
            .err => {},
        }
        return;
    }

    cleanupValue(value, allocator);
}

fn cleanupValue(value: anytype, allocator: std.mem.Allocator) void {
    const T = @TypeOf(value);

    if (T == SupportedTerm) {
        var owned = value;
        owned.deinit(allocator);
        return;
    }

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and !ptr.is_const and ptr.child == SupportedTerm) {
                deinitTermSlice(allocator, value);
                return;
            }
            if (ptr.size == .slice and !ptr.is_const and ptr.child == u8) {
                allocator.free(value);
                return;
            }
        },
        else => {},
    }
}

fn deinitTermSlice(allocator: std.mem.Allocator, slice: []SupportedTerm) void {
    for (slice) |*item| {
        item.deinit(allocator);
    }
    allocator.free(slice);
}

fn encodeValue(env: *c.ErlNifEnv, value: anytype, allocator: std.mem.Allocator) Term {
    const T = @TypeOf(value);

    if (T == Term) return value;
    if (T == Atom) return makeAtom(env, value.name);
    if (T == SupportedTerm) return encodeSupportedTerm(env, &value, allocator);

    switch (@typeInfo(T)) {
        .int => |info| switch (info.signedness) {
            .signed => return c.enif_make_int64(env, @intCast(value)),
            .unsigned => return c.enif_make_uint64(env, @intCast(value)),
        },
        .comptime_int => return c.enif_make_int64(env, @intCast(value)),
        .bool => return if (value) makeAtom(env, "true") else makeAtom(env, "false"),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return makeBinary(env, value, allocator);
            }
            if (ptr.size == .slice and ptr.child == SupportedTerm) {
                return makeTermList(env, value, allocator);
            }
            if (ptr.size == .one and ptr.child == SupportedTerm) {
                return encodeSupportedTerm(env, value, allocator);
            }
        },
        else => {},
    }

    return c.enif_make_badarg(env);
}

fn makeBinary(env: *c.ErlNifEnv, value: []const u8, allocator: std.mem.Allocator) Term {
    _ = allocator;
    var bin: c.ErlNifBinary = undefined;
    if (c.enif_alloc_binary(value.len, &bin) == 0) {
        return c.enif_make_badarg(env);
    }
    std.mem.copyForwards(u8, bin.data[0..value.len], value);
    return c.enif_make_binary(env, &bin);
}

fn makeTermList(env: *c.ErlNifEnv, items: []const SupportedTerm, allocator: std.mem.Allocator) Term {
    const terms = allocator.alloc(Term, items.len) catch return c.enif_make_badarg(env);
    defer allocator.free(terms);

    for (items, 0..) |item, idx| {
        terms[idx] = encodeSupportedTerm(env, &item, allocator);
    }

    return c.enif_make_list_from_array(env, terms.ptr, @intCast(items.len));
}

pub fn encodeSupportedTerm(env: *c.ErlNifEnv, term: *const SupportedTerm, allocator: std.mem.Allocator) Term {
    return switch (term.*) {
        .Integer => |value| c.enif_make_int64(env, value),
        .Atom => |value| makeAtom(env, value),
        .Bitstring => |value| makeBinary(env, value, allocator),
        .Tuple => |items| makeTermTuple(env, items, allocator),
        .List => |items| makeTermList(env, items, allocator),
    };
}

fn makeTermTuple(env: *c.ErlNifEnv, items: []const SupportedTerm, allocator: std.mem.Allocator) Term {
    const terms = allocator.alloc(Term, items.len) catch return c.enif_make_badarg(env);
    defer allocator.free(terms);

    for (items, 0..) |item, idx| {
        terms[idx] = encodeSupportedTerm(env, &item, allocator);
    }

    return c.enif_make_tuple_from_array(env, terms.ptr, @intCast(items.len));
}

pub fn decodeArg(comptime T: type, env: *c.ErlNifEnv, term: Term, allocator: std.mem.Allocator) DecodeError!T {
    if (T == Term) return term;

    if (T == SupportedTerm) {
        return decodeSupportedTerm(env, term, allocator);
    }

    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness == .signed) {
                var value: i64 = 0;
                if (c.enif_get_int64(env, term, &value) == 0) return error.BadArg;
                return @intCast(value);
            }

            var value: u64 = 0;
            if (c.enif_get_uint64(env, term, &value) == 0) return error.BadArg;
            return @intCast(value);
        },
        .comptime_int => {
            var value: i64 = 0;
            if (c.enif_get_int64(env, term, &value) == 0) return error.BadArg;
            return @intCast(value);
        },
        .pointer => |ptr| {
            const child = ptr.child;
            if (ptr.size == .slice and child == SupportedTerm) {
                return decodeSupportedTermList(env, term, allocator);
            }

            if (@hasDecl(child, "resource_type")) {
                return decodeResource(child, env, term);
            }
        },
        else => {},
    }

    return error.BadArg;
}

fn decodeResource(comptime T: type, env: *c.ErlNifEnv, term: Term) DecodeError!*T {
    const resource_type = @field(T, "resource_type") orelse return error.BadReference;
    var out: ?*anyopaque = null;
    if (c.enif_get_resource(env, term, resource_type, &out) == 0) {
        return error.BadReference;
    }
    return @ptrCast(@alignCast(out.?));
}

fn decodeSupportedTerm(env: *c.ErlNifEnv, term: Term, allocator: std.mem.Allocator) DecodeError!SupportedTerm {
    if (c.enif_is_number(env, term) != 0) {
        var value: i64 = 0;
        if (c.enif_get_int64(env, term, &value) == 0) return error.UnsupportedType;
        return .{ .Integer = value };
    }

    if (c.enif_is_atom(env, term) != 0) {
        var length: c_uint = 0;
        if (c.enif_get_atom_length(env, term, &length, c.ERL_NIF_UTF8) == 0) {
            return error.UnsupportedType;
        }

        const tmp = allocator.alloc(u8, length + 1) catch return error.BadArg;
        defer allocator.free(tmp);
        if (c.enif_get_atom(env, term, tmp.ptr, @intCast(tmp.len), c.ERL_NIF_UTF8) == 0) {
            return error.UnsupportedType;
        }

        const buf = allocator.alloc(u8, length) catch return error.BadArg;
        std.mem.copyForwards(u8, buf, tmp[0..length]);
        return .{ .Atom = buf };
    }

    if (c.enif_is_tuple(env, term) != 0) {
        var arity: c_int = 0;
        var tuple_terms: [*c]const Term = undefined;
        if (c.enif_get_tuple(env, term, &arity, &tuple_terms) == 0) {
            return error.UnsupportedType;
        }

        const count: usize = @intCast(arity);
        const items = allocator.alloc(SupportedTerm, count) catch return error.BadArg;
        var idx: usize = 0;
        errdefer {
            while (idx > 0) {
                idx -= 1;
                items[idx].deinit(allocator);
            }
            allocator.free(items);
        }

        while (idx < count) : (idx += 1) {
            items[idx] = try decodeSupportedTerm(env, tuple_terms[idx], allocator);
        }

        return .{ .Tuple = items };
    }

    if (c.enif_is_list(env, term) != 0) {
        const items = try decodeSupportedTermList(env, term, allocator);
        return .{ .List = items };
    }

    if (c.enif_is_binary(env, term) != 0) {
        var bin: c.ErlNifBinary = undefined;
        if (c.enif_inspect_binary(env, term, &bin) == 0) return error.UnsupportedType;

        const bytes = bin.data[0..bin.size];
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.UnsupportedType;

        const buf = allocator.alloc(u8, bytes.len) catch return error.BadArg;
        std.mem.copyForwards(u8, buf, bytes);
        return .{ .Bitstring = buf };
    }

    return error.UnsupportedType;
}

fn decodeSupportedTermList(env: *c.ErlNifEnv, term: Term, allocator: std.mem.Allocator) DecodeError![]SupportedTerm {
    var length: c_uint = 0;
    if (c.enif_get_list_length(env, term, &length) == 0) return error.UnsupportedType;

    const count: usize = @intCast(length);
    const items = allocator.alloc(SupportedTerm, count) catch return error.BadArg;

    var list = term;
    var idx: usize = 0;
    errdefer {
        while (idx > 0) {
            idx -= 1;
            items[idx].deinit(allocator);
        }
        allocator.free(items);
    }

    while (idx < count) : (idx += 1) {
        var head: Term = undefined;
        var tail: Term = undefined;
        if (c.enif_get_list_cell(env, list, &head, &tail) == 0) return error.UnsupportedType;
        items[idx] = try decodeSupportedTerm(env, head, allocator);
        list = tail;
    }

    return items;
}
