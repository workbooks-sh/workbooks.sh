// Demonstrator: a tool authored in Zig, compiled to a wasm32-wasi command.
// Proves the zigbuild: path (author commands in Zig → sandboxed wasm).
const std = @import("std");
pub fn main() void {
    var s: u32 = 0;
    var i: u32 = 1;
    while (i <= 10) : (i += 1) s += i;
    std.debug.print("zig command via our runtime: {d}\n", .{s});
}
