//! dev — the push-to-live loop. Watch the `.work` tree; on any change re-weave the workbook (and,
//! when a nexus is configured, hot-swap it for instant reload — wired in Z3). Dependency-free: a
//! content fingerprint polled ~500ms. A per-tick arena keeps the long-running loop flat in memory.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const weave = @import("weave.zig");
const log = @import("log.zig");

pub fn dev(io: Io, base: std.mem.Allocator, dir: []const u8, out: []const u8) !u8 {
    _ = try weave.weave(io, base, dir, out);
    log.step(try std.fmt.allocPrint(base, "watching {s}/**/*.work \u{2014} Ctrl-C to stop", .{dir}));

    var loop_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer loop_arena.deinit();

    var last = fingerprint(io, base, dir) catch 0;
    while (true) {
        try io.sleep(.fromNanoseconds(500 * std.time.ns_per_ms), .awake);
        _ = loop_arena.reset(.retain_capacity);
        const a = loop_arena.allocator();

        const fp = fingerprint(io, a, dir) catch last;
        if (fp != last) {
            last = fp;
            log.prompt("work dev \u{b7} change");
            _ = try weave.weave(io, a, dir, out);
        }
    }
    return 0;
}

fn fingerprint(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u64 {
    const files = try fs.workFiles(io, alloc, dir);
    var h = std.hash.Wyhash.init(0);
    for (files) |f| {
        h.update(f);
        const src = fs.readFile(io, alloc, f) catch continue;
        h.update(src);
    }
    return h.final();
}
