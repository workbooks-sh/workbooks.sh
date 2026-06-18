//! The output facade — the demo `.term` palette as ANSI (24-bit truecolor), the same design across
//! the whole CLI. Native colorizes a TTY; the wasm sandbox build defaults to plain. JSON mode (for
//! agents) lands with the verbs that need it.
const std = @import("std");
const builtin = @import("builtin");

var color_on: bool = builtin.target.os.tag != .wasi;
var g_io: ?std.Io = null;

pub fn setColor(on: bool) void {
    color_on = on;
}

pub fn setIo(io: std.Io) void {
    g_io = io;
}

pub fn out(bytes: []const u8) void {
    if (g_io) |io| {
        std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

// palette (truecolor)
pub const prompt_c = "\x1b[38;2;174;229;194m";
pub const cmd_c = "\x1b[1m\x1b[38;2;255;255;255m";
pub const ok_c = "\x1b[38;2;127;214;160m";
pub const warn_c = "\x1b[38;2;227;179;65m";
pub const err_c = "\x1b[38;2;235;120;120m";
pub const path_c = "\x1b[38;2;143;199;240m";
pub const num_c = "\x1b[38;2;231;184;148m";
pub const dim_c = "\x1b[38;2;126;133;144m";
pub const reset = "\x1b[0m";

fn c(code: []const u8) []const u8 {
    return if (color_on) code else "";
}

pub fn prompt(text: []const u8) void {
    print("{s}\u{27e8}{s} {s}{s}{s}\n", .{ c(prompt_c), c(reset), c(cmd_c), text, c(reset) });
}

pub fn ok(text: []const u8) void {
    print("{s}\u{2713}{s} {s}\n", .{ c(ok_c), c(reset), text });
}

pub fn warn(text: []const u8) void {
    print("{s}\u{26a0}{s} {s}\n", .{ c(warn_c), c(reset), text });
}

pub fn err(text: []const u8) void {
    print("{s}\u{2717}{s} {s}\n", .{ c(err_c), c(reset), text });
}

pub fn step(text: []const u8) void {
    print("{s}\u{b7}{s} {s}\n", .{ c(dim_c), c(reset), text });
}

pub fn info(text: []const u8) void {
    print("{s}\n", .{text});
}
