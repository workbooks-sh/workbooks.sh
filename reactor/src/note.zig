//! `work note` — explore the hash-note repository. The human/standalone navigation surface
//! over the `+#`/`-#`/`≡<hash>` lane. Self-contained and git-backed: live notes + handles come
//! from parsing `.work` source (reusing work.parse), and a collapsed note's full text is
//! recovered from git (`git show <ref>:<file>`) — NO nexus dependency. The nexus drawer is a hot
//! mirror for agents; this CLI is the cold, always-available path.
//!
//! Verbs: list · grep <q> · near <file> · expand <hash>
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

pub fn run(io: Io, alloc: std.mem.Allocator, sub: []const u8, arg: []const u8, dir: []const u8) !u8 {
    if (eql(sub, "expand") or eql(sub, "show")) return expand(io, alloc, arg, dir);
    if (eql(sub, "grep")) return list(io, alloc, dir, arg, "");
    if (eql(sub, "near")) return list(io, alloc, dir, "", arg);
    // `list [dir]` takes no arg — the path, if any, arrives as `arg`.
    if (eql(sub, "list") or eql(sub, "")) return list(io, alloc, if (arg.len > 0) arg else dir, "", "");
    log.err(try std.fmt.allocPrint(alloc, "unknown: work note {s} (try list | grep <q> | near <file> | expand <hash>)", .{sub}));
    return 1;
}

// List every hash note across the tree, optionally filtered by a substring `query` (grep) or a
// `file` (near). Pure: parser only, no git, no nexus.
fn list(io: Io, alloc: std.mem.Allocator, dir: []const u8, query: []const u8, file: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);
    var found: usize = 0;

    if (query.len > 0) {
        log.prompt(try std.fmt.allocPrint(alloc, "work note grep \"{s}\" {s}", .{ query, dir }));
    } else if (file.len > 0) {
        log.prompt(try std.fmt.allocPrint(alloc, "work note near {s}", .{file}));
    } else {
        log.prompt(try std.fmt.allocPrint(alloc, "work note list {s}", .{dir}));
    }

    for (files) |f| {
        if (file.len > 0 and std.mem.indexOf(u8, f, file) == null) continue;
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        var shown_file = false;
        for (nodes) |n| {
            if (n.type != .note) continue;
            if (query.len > 0 and std.mem.indexOf(u8, n.text, query) == null and
                std.mem.indexOf(u8, n.hash, query) == null) continue;
            if (!shown_file) {
                log.print("\n{s}\n", .{f});
                shown_file = true;
            }
            found += 1;
            try printNote(alloc, n);
        }
    }

    if (found == 0) log.step("no matching hash notes");
    return 0;
}

fn printNote(alloc: std.mem.Allocator, n: work.Node) !void {
    if (n.collapsed) {
        log.print("  \u{2261}{s}  {s}\n", .{ n.hash, n.text });
    } else {
        const m: u8 = if (n.note_marker == '+') '+' else '-';
        const tag: []const u8 = if (m == '+') "pin " else "drwr";
        log.print("  {c}# [{s}] {s}\n", .{ m, tag, n.text });
        _ = alloc;
    }
}

// Expand a `≡<hash>` handle to its full note. The handle's location comes from source (we parse
// for it); the FULL text comes from git — `git show <ref>:<file>` is the file version where the
// note was still live, so we scan it for the `+#`/`-#` line. Falls back to the in-source summary.
fn expand(io: Io, alloc: std.mem.Allocator, hash: []const u8, dir: []const u8) !u8 {
    if (hash.len == 0) {
        log.err("usage: work note expand <hash>");
        return 1;
    }
    log.prompt(try std.fmt.allocPrint(alloc, "work note expand {s}", .{hash}));

    const files = try fs.workFiles(io, alloc, dir);
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| if (n.type == .note and n.collapsed and std.mem.eql(u8, n.hash, hash)) {
            log.print("\n\u{2261}{s}  ({s})\n", .{ hash, f });
            if (n.text.len > 0) log.print("  summary: {s}\n", .{n.text});

            const ref = gitRef(hash);
            const rel = relTo(f, dir);
            const full = recover(io, alloc, dir, ref, rel) catch null;
            if (full) |text| {
                log.print("  full:    {s}\n", .{text});
            } else {
                log.step("full text not recoverable from git here (drawer holds it; summary above)");
            }
            return 0;
        };
    }

    log.err(try std.fmt.allocPrint(alloc, "no \u{2261}{s} handle found under {s}", .{ hash, dir }));
    return 1;
}

// The git-meaningful prefix of a handle (`a3f9.1` → `a3f9`).
fn gitRef(handle: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, handle, '.')) |i| handle[0..i] else handle;
}

fn relTo(path: []const u8, dir: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, dir)) {
        var r = path[dir.len..];
        while (r.len > 0 and (r[0] == '/' or r[0] == '.')) r = r[1..];
        return r;
    }
    return path;
}

// `git -C <dir> show <ref>:<rel>` → scan for the live `+#`/`-#` note line, return its text.
fn recover(io: Io, alloc: std.mem.Allocator, dir: []const u8, ref: []const u8, rel: []const u8) !?[]const u8 {
    const spec = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ ref, rel });
    const res = std.process.run(alloc, io, .{ .argv = &.{ "git", "-C", dir, "show", spec } }) catch return null;
    if (!(res.term == .exited and res.term.exited == 0)) return null;

    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (t.len >= 2 and (t[0] == '+' or t[0] == '-') and t[1] == '#') {
            return std.mem.trim(u8, t[2..], " \t\r");
        }
    }
    return null;
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
