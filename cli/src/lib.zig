//! The toolchain as a wasm REACTOR — the fast path for "nexus uses the ONE Zig toolchain". Unlike the
//! CLI command (re-instantiated per call, ~8ms), a reactor is instantiated ONCE by the host and its
//! exports called many times (~µs). Pure compute (no wasi) over a bump allocator: the host writes the
//! `.work` source into a guest buffer (`alloc`), calls `parse_units`, reads the result string from
//! guest memory, then `reset`s. Result format = the conformance golden's `name|kind|lang\n…`.
const std = @import("std");
const work = @import("work.zig");

var buf: [8 * 1024 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);

export fn alloc(len: usize) [*]u8 {
    const m = fba.allocator().alloc(u8, len) catch unreachable;
    return m.ptr;
}

export fn reset() void {
    fba.reset();
}

/// Parse `.work` text (ptr/len in guest memory) → the units as `name|kind|lang\n…`. Returns the
/// result packed as `(ptr << 32) | len`; the host reads `len` bytes at `ptr` from guest memory.
export fn parse_units(ptr: [*]const u8, len: usize) u64 {
    const a = fba.allocator();
    var out: std.ArrayList(u8) = .empty;
    const nodes = work.parse(a, ptr[0..len]) catch return 0;
    for (nodes) |n| {
        if (n.type == .code and n.name.len > 0) {
            out.appendSlice(a, n.name) catch return 0;
            out.append(a, '|') catch return 0;
            out.appendSlice(a, n.kind) catch return 0;
            out.append(a, '|') catch return 0;
            out.appendSlice(a, n.lang) catch return 0;
            out.append(a, '\n') catch return 0;
        }
    }
    return (@as(u64, @intFromPtr(out.items.ptr)) << 32) | out.items.len;
}
