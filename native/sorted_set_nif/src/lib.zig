const std = @import("std");
const nif = @import("nif_utils.zig");
const Configuration = @import("configuration.zig").Configuration;
const SortedSet = @import("sorted_set.zig").SortedSet;
const SupportedTerm = @import("supported_term.zig").SupportedTerm;

const SortedSetResource = struct {
    pub var resource_type: ?*nif.c.ErlNifResourceType = null;
    mutex: std.Thread.Mutex = .{},
    set: SortedSet,
};

const atoms = struct {
    const ok = nif.atom("ok");
    const bad_reference = nif.atom("bad_reference");
    const lock_fail = nif.atom("lock_fail");
    const added = nif.atom("added");
    const duplicate = nif.atom("duplicate");
    const removed = nif.atom("removed");
    const unsupported_type = nif.atom("unsupported_type");
    const not_found = nif.atom("not_found");
    const index_out_of_bounds = nif.atom("index_out_of_bounds");
    const max_bucket_size_exceeded = nif.atom("max_bucket_size_exceeded");
    const jemalloc_not_supported = nif.atom("jemalloc_not_supported");
};

fn sortedSetResourceDtor(_: ?*nif.c.ErlNifEnv, obj: ?*anyopaque) callconv(.c) void {
    if (obj == null) return;
    const resource: *SortedSetResource = @ptrCast(@alignCast(obj.?));
    resource.set.deinit();
}

fn load(env: ?*nif.c.ErlNifEnv, _: [*c]?*anyopaque, _: nif.Term) callconv(.c) c_int {
    const env_ptr = env orelse return 1;
    SortedSetResource.resource_type = nif.c.enif_open_resource_type(
        env_ptr,
        null,
        "sorted_set_resource",
        sortedSetResourceDtor,
        nif.c.ERL_NIF_RT_CREATE | nif.c.ERL_NIF_RT_TAKEOVER,
        null,
    );

    return if (SortedSetResource.resource_type == null) 1 else 0;
}

fn reload(env: ?*nif.c.ErlNifEnv, priv_data: [*c]?*anyopaque, load_info: nif.Term) callconv(.c) c_int {
    return load(env, priv_data, load_info);
}

fn upgrade(env: ?*nif.c.ErlNifEnv, priv_data: [*c]?*anyopaque, _: [*c]?*anyopaque, load_info: nif.Term) callconv(.c) c_int {
    return load(env, priv_data, load_info);
}

fn empty(env: nif.Env, initial_item_capacity: usize, max_bucket_size: usize) nif.Result(nif.Term) {
    const initial_set_capacity = (initial_item_capacity / max_bucket_size) + 1;
    const configuration = Configuration.init(max_bucket_size, initial_set_capacity);

    const resource_type = SortedSetResource.resource_type orelse return .{ .err = atoms.bad_reference };
    const raw_resource = nif.c.enif_alloc_resource(resource_type, @sizeOf(SortedSetResource)) orelse {
        return .{ .err = atoms.bad_reference };
    };

    const resource: *SortedSetResource = @ptrCast(@alignCast(raw_resource));
    resource.* = .{ .set = SortedSet.empty(nif.beam_allocator, configuration) };

    const term = nif.c.enif_make_resource(env.raw, resource);
    nif.c.enif_release_resource(resource);

    return .{ .ok = term };
}

fn new(env: nif.Env, initial_item_capacity: usize, max_bucket_size: usize) nif.Result(nif.Term) {
    const initial_set_capacity = (initial_item_capacity / max_bucket_size) + 1;
    const configuration = Configuration.init(max_bucket_size, initial_set_capacity);

    const resource_type = SortedSetResource.resource_type orelse return .{ .err = atoms.bad_reference };
    const raw_resource = nif.c.enif_alloc_resource(resource_type, @sizeOf(SortedSetResource)) orelse {
        return .{ .err = atoms.bad_reference };
    };

    const resource: *SortedSetResource = @ptrCast(@alignCast(raw_resource));
    resource.* = .{ .set = SortedSet.new(nif.beam_allocator, configuration) };

    const term = nif.c.enif_make_resource(env.raw, resource);
    nif.c.enif_release_resource(resource);

    return .{ .ok = term };
}

fn append_bucket(_: nif.Env, resource: *SortedSetResource, items: []SupportedTerm) nif.Result(nif.Atom) {
    if (!resource.mutex.tryLock()) {
        deinitTermSlice(items);
        return .{ .err = atoms.lock_fail };
    }
    defer resource.mutex.unlock();

    return switch (resource.set.appendBucket(items)) {
        .Ok => .{ .ok = atoms.ok },
        .MaxBucketSizeExceeded => .{ .err = atoms.max_bucket_size_exceeded },
    };
}

fn add(env: nif.Env, resource: *SortedSetResource, item: SupportedTerm) nif.Result(nif.Term) {
    if (!resource.mutex.tryLock()) {
        var owned = item;
        owned.deinit(nif.beam_allocator);
        return .{ .err = atoms.lock_fail };
    }
    defer resource.mutex.unlock();

    return switch (resource.set.add(item)) {
        .Added => |idx| .{ .ok = makeTaggedIndex(env.raw, atoms.added, idx) },
        .Duplicate => |idx| .{ .ok = makeTaggedIndex(env.raw, atoms.duplicate, idx) },
    };
}

fn remove(env: nif.Env, resource: *SortedSetResource, item: SupportedTerm) nif.Result(nif.Term) {
    var owned = item;
    defer owned.deinit(nif.beam_allocator);

    if (!resource.mutex.tryLock()) {
        return .{ .err = atoms.lock_fail };
    }
    defer resource.mutex.unlock();

    return switch (resource.set.remove(&owned)) {
        .Removed => |idx| .{ .ok = makeTaggedIndex(env.raw, atoms.removed, idx) },
        .NotFound => .{ .err = atoms.not_found },
    };
}

fn size(_: nif.Env, resource: *SortedSetResource) nif.Result(usize) {
    if (!resource.mutex.tryLock()) return .{ .err = atoms.lock_fail };
    defer resource.mutex.unlock();

    return .{ .ok = resource.set.size() };
}

fn to_list(_: nif.Env, resource: *SortedSetResource) nif.Result([]SupportedTerm) {
    if (!resource.mutex.tryLock()) return .{ .err = atoms.lock_fail };
    defer resource.mutex.unlock();

    return .{ .ok = resource.set.toVec() };
}

fn at(_: nif.Env, resource: *SortedSetResource, index: usize) nif.Result(*const SupportedTerm) {
    if (!resource.mutex.tryLock()) return .{ .err = atoms.lock_fail };
    defer resource.mutex.unlock();

    const item = resource.set.at(index) orelse return .{ .err = atoms.index_out_of_bounds };
    return .{ .ok = item };
}

fn slice(_: nif.Env, resource: *SortedSetResource, start: usize, amount: usize) nif.Result([]SupportedTerm) {
    if (!resource.mutex.tryLock()) return .{ .err = atoms.lock_fail };
    defer resource.mutex.unlock();

    return .{ .ok = resource.set.slice(start, amount) };
}

fn find_index(_: nif.Env, resource: *SortedSetResource, item: SupportedTerm) nif.Result(usize) {
    var owned = item;
    defer owned.deinit(nif.beam_allocator);

    if (!resource.mutex.tryLock()) return .{ .err = atoms.lock_fail };
    defer resource.mutex.unlock();

    return switch (resource.set.findIndex(&owned)) {
        .Found => |found| .{ .ok = found.idx },
        .NotFound => .{ .err = atoms.not_found },
    };
}

fn debug(_: nif.Env, resource: *SortedSetResource) nif.Result([]u8) {
    if (!resource.mutex.tryLock()) return .{ .err = atoms.lock_fail };
    defer resource.mutex.unlock();

    return .{ .ok = resource.set.debug(nif.beam_allocator) };
}

fn jemalloc_allocation_info(_: nif.Env) nif.Result(nif.Atom) {
    return .{ .err = atoms.jemalloc_not_supported };
}

fn makeTaggedIndex(env: *nif.c.ErlNifEnv, tag: nif.Atom, index: usize) nif.Term {
    const idx_term = nif.c.enif_make_uint64(env, @intCast(index));
    return nif.makeTuple2(env, nif.makeAtom(env, tag.name), idx_term);
}

fn deinitTermSlice(items: []SupportedTerm) void {
    for (items) |*item| {
        item.deinit(nif.beam_allocator);
    }
    nif.beam_allocator.free(items);
}

var nif_funcs = [_]nif.c.ErlNifFunc{
    .{ .name = "empty", .arity = 2, .fptr = nif.wrap(empty), .flags = 0 },
    .{ .name = "new", .arity = 2, .fptr = nif.wrap(new), .flags = 0 },
    .{ .name = "append_bucket", .arity = 2, .fptr = nif.wrap(append_bucket), .flags = 0 },
    .{ .name = "size", .arity = 1, .fptr = nif.wrap(size), .flags = 0 },
    .{ .name = "to_list", .arity = 1, .fptr = nif.wrap(to_list), .flags = 0 },
    .{ .name = "add", .arity = 2, .fptr = nif.wrap(add), .flags = 0 },
    .{ .name = "remove", .arity = 2, .fptr = nif.wrap(remove), .flags = 0 },
    .{ .name = "at", .arity = 2, .fptr = nif.wrap(at), .flags = 0 },
    .{ .name = "slice", .arity = 3, .fptr = nif.wrap(slice), .flags = 0 },
    .{ .name = "find_index", .arity = 2, .fptr = nif.wrap(find_index), .flags = 0 },
    .{ .name = "debug", .arity = 1, .fptr = nif.wrap(debug), .flags = 0 },
    .{ .name = "jemalloc_allocation_info", .arity = 0, .fptr = nif.wrap(jemalloc_allocation_info), .flags = 0 },
};

var nif_entry = nif.c.ErlNifEntry{
    .major = nif.c.ERL_NIF_MAJOR_VERSION,
    .minor = nif.c.ERL_NIF_MINOR_VERSION,
    .name = "Elixir.Discord.SortedSet.NifBridge",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = load,
    .reload = reload,
    .upgrade = upgrade,
    .unload = null,
    .vm_variant = nif.c.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = @sizeOf(nif.c.ErlNifResourceTypeInit),
    .min_erts = nif.c.ERL_NIF_MIN_ERTS_VERSION,
};

export fn nif_init() *nif.c.ErlNifEntry {
    return &nif_entry;
}
