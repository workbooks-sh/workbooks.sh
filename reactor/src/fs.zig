//! The file/dir seam over the 0.16 `Io`. Native reads the real filesystem; in the wasm sandbox the
//! same calls hit the preopened dirs the runtime grants. One code path, both targets.
const std = @import("std");
const Io = std.Io;

pub fn readFile(io: Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

/// Every `.work` file under `dir_path` (recursive), as full paths. Empty on a missing dir.
pub fn workFiles(io: Io, alloc: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return list.toOwnedSlice(alloc);
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".work")) {
            try list.append(alloc, try std.fs.path.join(alloc, &.{ dir_path, entry.path }));
        }
    }
    return list.toOwnedSlice(alloc);
}

pub fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}
