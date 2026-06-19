//! skills — author a skill ONCE, as docs. An `app` composition living under
//! `<docs>/skills/*.work` names a SUBSET of doc pages; this assembles them into a
//! Claude-standard skill BUNDLE beside the source:
//!
//!   <docs>/skills/<name>/SKILL.md            frontmatter + overview + reference index
//!   <docs>/skills/<name>/references/*.work    each composed page, loaded on demand
//!
//! So a skill for any agent that reads the SKILL.md standard (Claude Code, Claude
//! Desktop, claude.ai, …) is GENERATED from the documentation, never hand-edited —
//! one source of truth, zero drift. Progressive disclosure falls out of the doc
//! structure: SKILL.md is thin and links the depth; the agent pulls a reference only
//! when it needs it. References stay `.work` on purpose — a skill that teaches `.work`
//! is itself `.work`, so "no markdown in workbooks" enforces itself.
//!
//! Reuses the same `app`/`section`/`page` convention as a docs index — the ONLY
//! distinction is location (under `skills/`). No new literate kind. Generic mechanism:
//! any workbook author gets it; it carries none of our brand.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

const Buf = std.ArrayList(u8);

const Page = struct { slug: []const u8, title: []const u8, dek: []const u8, src: []const u8 };
const Group = struct { title: []const u8, pages: std.ArrayList(Page) };

/// Scan `<dir>/skills/*.work` and emit one skill bundle per app-composition. No-op if
/// the folder is absent. Called as a weave sidecar so skills re-assemble on every weave.
pub fn emit(io: Io, alloc: std.mem.Allocator, dir: []const u8) !void {
    const skills_dir = try std.fmt.allocPrint(alloc, "{s}/skills", .{dir});
    const files = fs.workFiles(io, alloc, skills_dir) catch return;
    for (files) |f| {
        // Skip our own generated references (they live in <name>/references/*.work).
        if (std.mem.indexOf(u8, f, "/references/") != null) continue;
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = work.parse(alloc, src) catch continue;
        emitOne(io, alloc, dir, nodes) catch |e| {
            log.warn(try std.fmt.allocPrint(alloc, "skill {s}: {s}", .{ f, @errorName(e) }));
        };
    }
}

fn emitOne(io: Io, alloc: std.mem.Allocator, dir: []const u8, nodes: []const work.Node) !void {
    // Find the app block; the prose before it (minus the file's own H1) is the overview.
    var app: ?work.Node = null;
    var overview: Buf = .empty;
    for (nodes) |n| {
        if (n.type == .code and std.mem.eql(u8, n.kind, "app")) {
            app = n;
            break;
        }
        if (n.type == .prose) {
            if (overview.items.len > 0) try overview.appendSlice(alloc, "\n\n");
            try overview.appendSlice(alloc, n.text);
        }
    }
    const a = app orelse return;

    const name: []const u8 = if (a.name.len > 0) a.name else "skill";
    var title: []const u8 = name;
    var desc: []const u8 = "";
    var groups: std.ArrayList(Group) = .empty;
    var cur: ?usize = null;
    var page_count: usize = 0;

    var lines = std.mem.splitScalar(u8, a.body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "title ")) {
            if (dquoted(line)) |t| title = t;
        } else if (std.mem.startsWith(u8, line, "description ")) {
            if (dquoted(line)) |t| desc = t;
        } else if (std.mem.startsWith(u8, line, "section ")) {
            if (dquoted(line)) |t| {
                try groups.append(alloc, .{ .title = t, .pages = .empty });
                cur = groups.items.len - 1;
            }
        } else if (std.mem.startsWith(u8, line, "page ")) {
            const path = dquoted(line) orelse continue;
            const file = try std.fmt.allocPrint(alloc, "{s}/{s}.work", .{ dir, path });
            const psrc = fs.readFile(io, alloc, file) catch {
                log.warn(try std.fmt.allocPrint(alloc, "skill {s}: missing page {s}", .{ name, path }));
                continue;
            };
            const pnodes = try work.parse(alloc, psrc);
            const page: Page = .{
                .slug = std.fs.path.basename(path),
                .title = pageTitle(pnodes, path),
                .dek = pageDek(pnodes),
                .src = psrc,
            };
            if (cur == null) {
                try groups.append(alloc, .{ .title = "", .pages = .empty });
                cur = 0;
            }
            try groups.items[cur.?].pages.append(alloc, page);
            page_count += 1;
        }
    }

    const base = try std.fmt.allocPrint(alloc, "{s}/skills/{s}", .{ dir, name });
    Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(alloc, "{s}/references", .{base})) catch {};

    // SKILL.md — frontmatter + GENERATED banner + overview + reference index.
    var md: Buf = .empty;
    try md.appendSlice(alloc, "---\n");
    try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "name: {s}\n", .{name}));
    if (desc.len > 0) try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "description: {s}\n", .{desc}));
    try md.appendSlice(alloc, "---\n\n");
    try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "# {s}\n\n", .{title}));
    try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<!-- GENERATED by `work weave` from skills/{s}.work — do not edit; edit the source docs it composes. -->\n\n", .{name}));
    if (overview.items.len > 0) {
        try md.appendSlice(alloc, overview.items);
        try md.appendSlice(alloc, "\n\n");
    }
    try md.appendSlice(alloc, "## References\n\nLoad a reference below only when you need that depth.\n");
    for (groups.items) |g| {
        if (g.pages.items.len == 0) continue;
        if (g.title.len > 0) try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n### {s}\n\n", .{g.title})) else try md.appendSlice(alloc, "\n");
        for (g.pages.items) |p| {
            try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, "- [{s}](references/{s}.work)", .{ p.title, p.slug }));
            if (p.dek.len > 0) try md.appendSlice(alloc, try std.fmt.allocPrint(alloc, " — {s}", .{p.dek}));
            try md.appendSlice(alloc, "\n");
            // Bundle the page source as an on-demand reference.
            const ref_path = try std.fmt.allocPrint(alloc, "{s}/references/{s}.work", .{ base, p.slug });
            try fs.writeFile(io, ref_path, p.src);
        }
    }

    try fs.writeFile(io, try std.fmt.allocPrint(alloc, "{s}/SKILL.md", .{base}), md.items);
    log.ok(try std.fmt.allocPrint(alloc, "skill {s} \u{b7} {d} ref(s) \u{b7} {d} B \u{2192} {s}/SKILL.md", .{ name, page_count, md.items.len, base }));
}

/// The page's first H1, or the path as a fallback.
fn pageTitle(nodes: []const work.Node, path: []const u8) []const u8 {
    for (nodes) |n| if (n.type == .heading and n.level == 1) return n.text;
    return path;
}

/// A one-line dek: the first sentence (or first line) of the page's first prose paragraph.
fn pageDek(nodes: []const work.Node) []const u8 {
    for (nodes) |n| {
        if (n.type != .prose) continue;
        var t = std.mem.trim(u8, n.text, " \t\r\n");
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[0..nl];
        if (std.mem.indexOf(u8, t, ". ")) |dot| t = t[0 .. dot + 1];
        return t;
    }
    return "";
}

/// First double-quoted substring of a line, or null.
fn dquoted(line: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse return null;
    return line[a + 1 .. b];
}
