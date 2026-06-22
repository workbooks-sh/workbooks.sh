//! The author verbs — `check` / `structure` — over a `.work` tree. Pure toolchain (parse + resolve);
//! the only I/O is reading files through the seam. Returns a process exit code.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

const Ref = struct { file: []const u8, label: []const u8 };

// ── auth/route policy validation (wb-dshz) ─────────────────────────────────────────────────────
// A malformed `protect`/`public`/`route` declaration should fail `work check` (and thus the weave/
// deploy), not surface at runtime — the RFC's "a malformed policy fails the weave" (fail-closed).
const PolicyErr = struct { file: []const u8, msg: []const u8 };
const http_methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "ANY" };

fn firstQuoted(line: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse return null;
    return line[a + 1 .. b];
}

fn knownMethod(m: []const u8) bool {
    for (http_methods) |k| if (std.ascii.eqlIgnoreCase(k, m)) return true;
    return false;
}

// "METHOD /path" or "/path" — if there are two tokens the first must be a known HTTP method.
fn validSpec(spec: []const u8) bool {
    const s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, ' ');
    const first = it.next() orelse return false;
    if (it.next() != null) return knownMethod(first);
    return true;
}

// Scan a unit body for `protect`/`public`/`route` lines and append a PolicyErr for each malformed one.
fn validatePolicy(alloc: std.mem.Allocator, body: []const u8, file: []const u8, errs: *std.ArrayList(PolicyErr)) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const directive: []const u8 =
            if (std.mem.startsWith(u8, line, "protect ")) "protect" else if (std.mem.startsWith(u8, line, "public ")) "public" else if (std.mem.startsWith(u8, line, "route ")) "route" else continue;

        const q = firstQuoted(line) orelse {
            try errs.append(alloc, .{ .file = file, .msg = try std.fmt.allocPrint(alloc, "`{s}` without a quoted spec", .{directive}) });
            continue;
        };

        if (!validSpec(q))
            try errs.append(alloc, .{ .file = file, .msg = try std.fmt.allocPrint(alloc, "`{s} \"{s}\"` — unknown HTTP method", .{ directive, q }) });

        if (std.mem.eql(u8, directive, "route")) {
            const open = std.mem.indexOfScalar(u8, line, '"') orelse 0;
            const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse line.len;
            const after = if (close + 1 <= line.len) line[close + 1 ..] else "";
            if (std.mem.indexOfScalar(u8, after, ':') == null)
                try errs.append(alloc, .{ .file = file, .msg = try std.fmt.allocPrint(alloc, "`route \"{s}\"` without a :handler", .{q}) });
        }
    }
}

pub fn check(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);

    var names: std.ArrayList([]const u8) = .empty;
    var titles: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList(Ref) = .empty;
    var perrs: std.ArrayList(PolicyErr) = .empty;
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
                // Only [[backlinks]] are resolvable references; :atom/@type/#tag/work:// are other
                // ref classes the parser captures (parity w/ the nexus) but `check` does not resolve.
                for (n.refs) |r| if (work.backlinkLabel(r)) |label| try refs.append(alloc, .{ .file = f, .label = label });
                try validatePolicy(alloc, n.body, f, &perrs);
            },
            .heading => try titles.append(alloc, n.text),
            .prose => for (n.refs) |r| if (work.backlinkLabel(r)) |label| try refs.append(alloc, .{ .file = f, .label = label }),
        };
    }

    log.prompt(try std.fmt.allocPrint(alloc, "work check {s}", .{dir}));

    var dangling: usize = 0;
    for (refs.items) |r| if (!resolves(r.label, names.items, titles.items)) {
        dangling += 1;
    };

    // Dangling [[backlinks]] are ADVISORY — often intentional cross-surface prose refs (e.g. [[the-line]]),
    // they never break a deploy. Report as a warning; do NOT fail.
    if (dangling > 0) {
        log.warn(try std.fmt.allocPrint(alloc, "{d} dangling ref(s) (advisory)", .{dangling}));
        for (refs.items) |r| if (!resolves(r.label, names.items, titles.items)) {
            log.step(try std.fmt.allocPrint(alloc, "dangling [[{s}]] in {s}", .{ r.label, std.fs.path.basename(r.file) }));
        };
    }

    // POLICY errors (auth/route) are FATAL — they break the deploy. Parse errors already fail earlier
    // (work.parse propagates). This makes `work check` a usable PRE-PUSH gate: exit 0 ⇒ safe to deploy.
    if (perrs.items.len > 0) {
        log.err(try std.fmt.allocPrint(alloc, "{d} unit(s) \u{b7} {d} policy error(s)", .{ units, perrs.items.len }));
        for (perrs.items) |e| {
            log.step(try std.fmt.allocPrint(alloc, "auth/route: {s} in {s}", .{ e.msg, std.fs.path.basename(e.file) }));
        }
        return 1;
    }

    log.ok(try std.fmt.allocPrint(alloc, "{d} units \u{b7} {d} refs \u{b7} auth/route policy valid", .{ units, refs.items.len }));
    return 0;
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
            // edges are [[backlink]] dependencies only (the resolvable code-graph refs).
            for (n.refs) |r| if (work.backlinkLabel(r)) |label| try list.append(alloc, .{ .from = n.name, .to = label });
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

test "auth/route policy validation: valid passes, malformed flagged" {
    const alloc = std.testing.allocator;

    var ok: std.ArrayList(PolicyErr) = .empty;
    defer ok.deinit(alloc);
    try validatePolicy(alloc,
        "protect \"/admin/**\", role: \"admin\"\npublic \"/\", \"/pricing\"\nroute \"GET /api/x\", :list",
        "ok.work", &ok);
    try std.testing.expectEqual(@as(usize, 0), ok.items.len);

    var bad: std.ArrayList(PolicyErr) = .empty;
    defer bad.deinit(alloc);
    try validatePolicy(alloc,
        "route /noquote\nroute \"GET /x\"\nprotect \"BADVERB /y\"",
        "bad.work", &bad);
    // route-without-quote, route-without-:handler, bad-method → at least 3
    try std.testing.expect(bad.items.len >= 3);
}
