//! The author verbs — `check` / `structure` — over a `.work` tree. Pure toolchain (parse + resolve);
//! the only I/O is reading files through the seam. Returns a process exit code.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

const Ref = struct { file: []const u8, label: []const u8 };

pub fn check(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);

    var names: std.ArrayList([]const u8) = .empty;
    var titles: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList(Ref) = .empty;
    var units: usize = 0;

    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| switch (n.type) {
            .code => {
                if (n.name.len > 0) {
                    try names.append(alloc, n.name);
                    units += 1;
                }
                for (n.refs) |r| try refs.append(alloc, .{ .file = f, .label = r });
            },
            .heading => try titles.append(alloc, n.text),
            .prose => for (n.refs) |r| try refs.append(alloc, .{ .file = f, .label = r }),
        };
    }

    log.prompt(try std.fmt.allocPrint(alloc, "work check {s}", .{dir}));

    var dangling: usize = 0;
    for (refs.items) |r| if (!resolves(r.label, names.items, titles.items)) {
        dangling += 1;
    };

    if (dangling == 0) {
        log.ok(try std.fmt.allocPrint(alloc, "{d} units \u{b7} {d} refs \u{b7} references resolve", .{ units, refs.items.len }));
        return 0;
    } else {
        log.err(try std.fmt.allocPrint(alloc, "{d} units \u{b7} {d} dangling ref(s)", .{ units, dangling }));
        for (refs.items) |r| if (!resolves(r.label, names.items, titles.items)) {
            log.step(try std.fmt.allocPrint(alloc, "dangling [[{s}]] in {s}", .{ r.label, std.fs.path.basename(r.file) }));
        };
        return 1;
    }
}

pub fn structure(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work structure {s}", .{dir}));

    var units: usize = 0;
    var lines: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| if (n.type == .code and n.name.len > 0) {
            units += 1;
            try lines.append(alloc, try std.fmt.allocPrint(alloc, ":{s}  {s} {s}  {s}", .{ n.name, n.kind, n.lang, std.fs.path.basename(f) }));
        };
    }

    log.ok(try std.fmt.allocPrint(alloc, "{d} unit(s)", .{units}));
    for (lines.items) |l| log.step(l);
    return 0;
}

fn resolves(label: []const u8, names: []const []const u8, titles: []const []const u8) bool {
    for (names) |n| if (eqlIgnoreCase(n, label)) return true;
    for (titles) |t| if (eqlIgnoreCase(t, label)) return true;
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}
