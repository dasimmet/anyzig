const std = @import("std");
const zig = @import("zig");
const LockFile = @import("LockFile.zig");
const Dir = std.Io.Dir;
const anyzig = @import("root");

pub fn init(io: std.Io, path: []const u8) !void {
    Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.NotDir => {
            try Dir.cwd().deleteFile(io, path);
            try Dir.cwd().createDirPath(io, path);
        },
        else => |e| return e,
    };
}

const Lock = struct {
    lockfile: LockFile,
    hashfile_path: []const u8,
    pub fn init(io: std.Io, arena: std.mem.Allocator, hashstore_path: []const u8, name: []const u8) !Lock {
        const lockfile_basename = std.fmt.allocPrint(arena, "{s}.lock", .{name}) catch |e| oom(e);
        const lockfile_path = std.fs.path.join(arena, &.{ hashstore_path, lockfile_basename }) catch |e| oom(e);
        var lockfile = try LockFile.lock(io, lockfile_path);
        errdefer lockfile.unlock();
        return .{
            .lockfile = lockfile,
            .hashfile_path = std.fs.path.join(arena, &.{ hashstore_path, name }) catch |e| oom(e),
        };
    }
    pub fn unlock(self: *Lock, io: std.Io) void {
        // no need to free anything allocated by the arena
        self.lockfile.unlock(io);
    }
};

pub fn find(io: std.Io, hashstore_path: []const u8, name: []const u8) !?zig.Package.Hash {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var lock = try Lock.init(io, arena, hashstore_path, name);
    defer lock.unlock(io);

    const full_content = Dir.cwd().readFileAlloc(
        io,
        lock.hashfile_path,
        arena,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };

    defer arena.free(full_content);
    const hash_bytes = std.mem.trim(u8, full_content, &std.ascii.whitespace);
    if (hash_bytes.len > zig.Package.Hash.max_len) {
        anyzig.log.warn(
            "{s}: file is too big (max is {})",
            .{ lock.hashfile_path, zig.Package.Hash.max_len },
        );
        try Dir.cwd().deleteFile(io, lock.hashfile_path);
        return null;
    }
    return zig.Package.Hash.fromSlice(hash_bytes);
}

pub fn save(io: std.Io, hashstore_path: []const u8, name: []const u8, content: []const u8) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var lock = try Lock.init(io, arena, hashstore_path, name);
    defer lock.unlock(io);
    // no need to write to a temporary file and rename since we have a lock file
    const store_file = try Dir.cwd().createFile(io, lock.hashfile_path, .{});
    defer store_file.close(io);
    try store_file.writeStreamingAll(io, content);
}

pub fn delete(io: std.Io, hashstore_path: []const u8, name: []const u8) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var lock = try Lock.init(io, arena, hashstore_path, name);
    defer lock.unlock(io);
    Dir.cwd().deleteFile(io, lock.hashfile_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

const ReverseLookup = std.AutoHashMapUnmanaged(
    zig.Package.Hash,
    std.ArrayListUnmanaged(anyzig.SemanticVersion),
);
pub fn allocReverseLookup(
    io: std.Io,
    hashstore_path: []const u8,
    allocator: std.mem.Allocator,
) !ReverseLookup {
    var dir = try Dir.cwd().createDirPathOpen(
        io,
        hashstore_path,
        .{ .open_options = .{ .iterate = true } },
    );
    defer dir.close(io);
    var map: ReverseLookup = .{};
    var it = dir.iterate();
    const prefix = anyzig.exe_str ++ "-";
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const version_str = entry.name[prefix.len..];
        const entry_version = anyzig.SemanticVersion.parse(version_str) orelse std.debug.panic(
            "entry '{s}' contains an invalid version '{s}'",
            .{ entry.name, version_str },
        );
        const hash = (try find(io, hashstore_path, entry.name)) orelse std.debug.panic(
            "hashstore entry '{s}' disappeared while iterating?",
            .{entry.name},
        );
        const map_entry = map.getOrPut(allocator, hash) catch |e| oom(e);
        if (!map_entry.found_existing) {
            map_entry.value_ptr.* = .empty;
        }
        map_entry.value_ptr.append(allocator, entry_version) catch |e| oom(e);
    }
    return map;
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
