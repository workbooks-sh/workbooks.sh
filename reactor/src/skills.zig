//! skills — author a skill ONCE, as docs. An `app` composition living under
//! `<docs>/skills/*.work` names a SUBSET of doc pages; this assembles them into a
//! markdown `SKILL.md` (YAML frontmatter + each composed page's `.work` source
//! verbatim) beside the source. So a Claude Code / Codex / Claude Desktop skill is
//! GENERATED from the documentation, never hand-edited — one source of truth, zero
//! drift. Reuses the same `app`/`section`/`page` convention as the site (see
//! site.zig): the ONLY distinction is location — an `app` under `skills/` assembles
//! to markdown, an `app` in the index assembles to the HTML site. No new kind.
//! Body stays `.work` source on purpose: a skill that teaches `.work` is itself
//! `.work`, so "no markdown in workbooks" enforces itself.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

const Buf = std.ArrayList(u8);

/// Scan `<dir>/skills/*.work` and emit one `SKILL.md` per app-composition. No-op if
/// the folder is absent. Called as a weave sidecar so skills re-assemble on every weave.
pub fn emit(io: Io, alloc: std.mem.Allocator, dir: []const u8) !void {
    const skills_dir = try std.fmt.allocPrint(alloc, "{s}/skills", .{dir});
    const files = fs.workFiles(io, alloc, skills_dir) catch return;
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = work.parse(alloc, src) catch continue;
        const app = findApp(nodes) orelse continue;
        emitOne(io, alloc, dir, app) catch |e| {
            log.warn(try std.fmt.allocPrint(alloc, "skill {s}: {s}", .{ f, @errorName(e) }));
        };
    }
}

fn findApp(nodes: []const work.Node) ?work.Node {
    for (nodes) |n| if (n.type == .code and std.mem.eql(u8, n.kind, "app")) return n;
    return null;
}

fn emitOne(io: Io, alloc: std.mem.Allocator, dir: []const u8, app: work.Node) !void {
    const name: []const u8 = if (app.name.len > 0) app.name else "skill";
    var title: []const u8 = name;
    var desc: []const u8 = "";
    var md: Buf = .empty;
    var pages: usize = 0;

    var lines = std.mem.splitScalar(u8, app.body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "title ")) {
            if (dquoted(line)) |t| title = t;
        } else if (std.mem.startsWith(u8, line, "description ")) {
            if (dquoted(line)) |t| desc = t;
        } else if (std.mem.startsWith(u8, line, "section ")) {
            if (dquoted(line)) |t| try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n## {s}\n\n", .{t}));
        } else if (std.mem.startsWith(u8, line, "page ")) {
            const path = dquoted(line) orelse continue;
            const file = try std.fmt.allocPrint(alloc, "{s}/{s}.work", .{ dir, path });
            const psrc = fs.readFile(io, alloc, file) catch {
                log.warn(try std.fmt.allocPrint(alloc, "skill {s}: missing page {s}", .{ name, path }));
                continue;
            };
            try md.appendSlice(alloc, psrc);
            try md.appendSlice(alloc, "\n\n");
            pages += 1;
        }
    }

    var out: Buf = .empty;
    try out.appendSlice(alloc, "---\n");
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "name: {s}\n", .{name}));
    if (desc.len > 0) try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "description: {s}\n", .{desc}));
    try out.appendSlice(alloc, "---\n\n");
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "# {s}\n\n", .{title}));
    try out.appendSlice(alloc, md.items);

    const out_dir = try std.fmt.allocPrint(alloc, "{s}/skills/{s}", .{ dir, name });
    Io.Dir.cwd().createDirPath(io, out_dir) catch {};
    const out_path = try std.fmt.allocPrint(alloc, "{s}/SKILL.md", .{out_dir});
    try fs.writeFile(io, out_path, out.items);
    log.ok(try std.fmt.allocPrint(alloc, "skill {s} \u{b7} {d} page(s) \u{b7} {d} B \u{2192} {s}", .{ name, pages, out.items.len, out_path }));
}

/// First double-quoted substring of a line, or null.
fn dquoted(line: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse return null;
    return line[a + 1 .. b];
}
