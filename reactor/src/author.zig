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

// `work graph <dir> <out.html>` — dogfood: the code graph rendered as a work-* workbook
// (the graph that maps the system is itself a workbook you can open). Structural floor —
// units + edges; the reality facets (interface/artifact/data/observed) are a nexus overlay.
const Unit = struct { name: []const u8, kind: []const u8, lang: []const u8, file: []const u8 };

pub fn graph(io: Io, alloc: std.mem.Allocator, dir: []const u8, out: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work graph {s} \u{2192} {s}", .{ dir, out }));

    var units: std.ArrayList(Unit) = .empty;
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| if (n.type == .code and n.name.len > 0) {
            try units.append(alloc, .{ .name = n.name, .kind = n.kind, .lang = n.lang, .file = std.fs.path.basename(f) });
        };
    }
    const es = try edges(io, alloc, dir);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "<!doctype html>\n<meta charset=\"utf-8\">\n<title>");
    try esc(alloc, &buf, dir);
    try buf.appendSlice(alloc, " \u{2014} system graph</title>\n<document-view>\n  <h1>");
    try esc(alloc, &buf, dir);
    try buf.appendSlice(alloc, " \u{2014} system graph</h1>\n  <document-outline>\n");
    for (units.items) |u| {
        try buf.appendSlice(alloc, "    <work-ref to=\"");
        try esc(alloc, &buf, u.name);
        try buf.appendSlice(alloc, "\">");
        try esc(alloc, &buf, u.name);
        try buf.appendSlice(alloc, "</work-ref>\n");
    }
    try buf.appendSlice(alloc, "  </document-outline>\n  <work-flow>\n");
    for (es) |e| {
        try buf.appendSlice(alloc, "    <work-ref rel=\"ref\" from=\"");
        try esc(alloc, &buf, e.from);
        try buf.appendSlice(alloc, "\" to=\"");
        try esc(alloc, &buf, e.to);
        try buf.appendSlice(alloc, "\"></work-ref>\n");
    }
    try buf.appendSlice(alloc, "  </work-flow>\n");
    for (units.items) |u| {
        try buf.appendSlice(alloc, "  <section id=\"");
        try esc(alloc, &buf, u.name);
        try buf.appendSlice(alloc, "\" data-kind=\"");
        try esc(alloc, &buf, u.kind);
        try buf.appendSlice(alloc, "\" data-lang=\"");
        try esc(alloc, &buf, u.lang);
        try buf.appendSlice(alloc, "\">\n    <h2>");
        try esc(alloc, &buf, u.name);
        try buf.appendSlice(alloc, "</h2>\n    <record-view>\n      <record-field-value name=\"kind\">");
        try esc(alloc, &buf, u.kind);
        try buf.appendSlice(alloc, "</record-field-value>\n      <record-field-value name=\"lang\">");
        try esc(alloc, &buf, u.lang);
        try buf.appendSlice(alloc, "</record-field-value>\n      <record-field-value name=\"file\">");
        try esc(alloc, &buf, u.file);
        try buf.appendSlice(alloc, "</record-field-value>\n      <record-field-value name=\"depends-on\">");
        var first = true;
        for (es) |e| if (eqlIgnoreCase(e.from, u.name)) {
            if (!first) try buf.appendSlice(alloc, ", ");
            try esc(alloc, &buf, e.to);
            first = false;
        };
        try buf.appendSlice(alloc, "</record-field-value>\n    </record-view>\n  </section>\n");
    }
    try buf.appendSlice(alloc, "</document-view>\n");

    try fs.writeFile(io, out, buf.items);
    log.ok(try std.fmt.allocPrint(alloc, "{s} \u{b7} {d} unit(s) \u{b7} {d} edge(s) \u{b7} {d} B", .{ std.fs.path.basename(out), units.items.len, es.len, buf.items.len }));
    log.step("reality facets (artifact/data/observed) need a nexus overlay");
    return 0;
}

fn esc(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try buf.appendSlice(alloc, "&amp;"),
        '<' => try buf.appendSlice(alloc, "&lt;"),
        '>' => try buf.appendSlice(alloc, "&gt;"),
        '"' => try buf.appendSlice(alloc, "&quot;"),
        else => try buf.append(alloc, ch),
    };
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
