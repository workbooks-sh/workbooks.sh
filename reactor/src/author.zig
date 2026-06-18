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

// ── code graph (edges from a unit's [[refs]]) — backs why/near ──────────────────────────────
const Edge = struct { from: []const u8, to: []const u8 };

fn edges(io: Io, alloc: std.mem.Allocator, dir: []const u8) ![]Edge {
    const files = try fs.workFiles(io, alloc, dir);
    var list: std.ArrayList(Edge) = .empty;
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| if (n.type == .code and n.name.len > 0) {
            for (n.refs) |r| try list.append(alloc, .{ .from = n.name, .to = r });
        };
    }
    return list.toOwnedSlice(alloc);
}

pub fn why(io: Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !u8 {
    const es = try edges(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work why :{s} {s}", .{ name, dir }));
    var found = false;
    for (es) |e| if (eqlIgnoreCase(e.to, name)) {
        found = true;
        log.step(try std.fmt.allocPrint(alloc, ":{s} \u{2190} :{s}", .{ name, e.from }));
    };
    if (!found) log.step(try std.fmt.allocPrint(alloc, "no unit depends on :{s}", .{name}));
    return 0;
}

pub fn near(io: Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !u8 {
    const es = try edges(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work near :{s} {s}", .{ name, dir }));
    var found = false;
    for (es) |e| if (eqlIgnoreCase(e.from, name) or eqlIgnoreCase(e.to, name)) {
        found = true;
        log.step(try std.fmt.allocPrint(alloc, ":{s} \u{2192} :{s}", .{ e.from, e.to }));
    };
    if (!found) log.step(try std.fmt.allocPrint(alloc, "no edges touch :{s}", .{name}));
    return 0;
}

pub fn lint(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u8 {
    return check(io, alloc, dir);
}

// ── wit: the generated WIT world for a unit (grants → imports + the run export) ──────────────
const caps = [_][2][]const u8{
    .{ "net", "host-net" }, .{ "kv", "host-kv" }, .{ "secrets", "host-secrets" },
    .{ "fs", "host-fs" },   .{ "exec", "host-exec" },
};

pub fn wit(io: Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work wit :{s} {s}", .{ name, dir }));

    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| if (n.type == .code and eqlIgnoreCase(n.name, name)) {
            log.out("\n");
            log.print("package work:{s};\n\nworld {s} {{\n", .{ name, name });
            for (caps) |c| if (headerGrants(n.header, c[0])) log.print("  import {s};\n", .{c[1]});
            log.out("  export run: func(input: string) -> string;\n}\n");
            return 0;
        };
    }
    log.err(try std.fmt.allocPrint(alloc, "no unit named :{s} under {s}", .{ name, dir }));
    return 1;
}

fn headerGrants(header: []const u8, cap: []const u8) bool {
    // a grant is present if `grant` appears and the cap word follows it somewhere in the header
    const g = std.mem.indexOf(u8, header, "grant") orelse return false;
    return std.mem.indexOfPos(u8, header, g, cap) != null;
}
