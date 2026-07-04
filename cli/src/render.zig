//! render — a `.work` node list → an HTML body fragment. The modern model: prose
//! is markdown, a `client` block's body is emitted verbatim (the browser island),
//! and any other unit renders as a labelled, syntax-plain source figure. No
//! `work-*` elements (that authoring model is dead) — the document IS the render.
const std = @import("std");
const work = @import("work.zig");

const Buf = std.ArrayList(u8);

/// Render a slice of parsed nodes into an HTML fragment.
pub fn nodes(alloc: std.mem.Allocator, ns: []const work.Node) ![]u8 {
    var buf: Buf = .empty;
    for (ns) |n| switch (n.type) {
        .heading => {
            try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<h{d}>", .{n.level}));
            try inlineMd(alloc, &buf, n.text);
            try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "</h{d}>\n", .{n.level}));
        },
        .prose => try prose(alloc, &buf, n.text),
        .code => try unit(alloc, &buf, n),
        // hash notes are ephemeral dev-context — STRIPPED from every render (the woven
        // artifact, the viewer). They live only in source + the drawer + git.
        .note => {},
    };
    return buf.items;
}

/// A `client` block is the island — its body is the page (emitted verbatim).
/// Everything else renders as a labelled source figure.
fn unit(alloc: std.mem.Allocator, buf: *Buf, n: work.Node) !void {
    if (std.mem.eql(u8, n.kind, "client")) {
        try buf.appendSlice(alloc, n.body);
        try buf.append(alloc, '\n');
        return;
    }
    try buf.appendSlice(alloc, try std.fmt.allocPrint(
        alloc,
        "<figure class=\"unit\" data-unit=\"{s}:{s}\"><figcaption><span class=\"kind\">{s}</span>",
        .{ n.kind, n.name, n.kind },
    ));
    if (n.lang.len != 0) try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, " <span class=\"lang\">{s}</span>", .{n.lang}));
    if (n.name.len != 0) try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, " <span class=\"nm\">:{s}</span>", .{n.name}));
    try buf.appendSlice(alloc, "</figcaption><pre><code>");
    try escape(alloc, buf, n.header);
    try buf.appendSlice(alloc, " do\n");
    try escape(alloc, buf, n.body);
    try buf.appendSlice(alloc, "\nend</code></pre></figure>\n");
}

/// A prose chunk: bullet lines become a list, otherwise a paragraph. Inline
/// markdown (`code`, **bold**, *italic*, [text](url)) is applied throughout.
fn prose(alloc: std.mem.Allocator, buf: *Buf, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;

    var bullets = std.mem.startsWith(u8, trimmed, "- ");
    if (bullets) {
        // every non-empty line must be a bullet
        var probe = std.mem.splitScalar(u8, trimmed, '\n');
        while (probe.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len != 0 and !std.mem.startsWith(u8, t, "- ")) {
                bullets = false;
                break;
            }
        }
    }

    if (bullets) {
        try buf.appendSlice(alloc, "<ul>\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len == 0) continue;
            try buf.appendSlice(alloc, "<li>");
            try inlineMd(alloc, buf, t[2..]);
            try buf.appendSlice(alloc, "</li>\n");
        }
        try buf.appendSlice(alloc, "</ul>\n");
        return;
    }

    try buf.appendSlice(alloc, "<p>");
    try inlineMd(alloc, buf, trimmed);
    try buf.appendSlice(alloc, "</p>\n");
}

/// Inline markdown: `code`, **bold**, *italic*, [text](url). HTML-escaped
/// throughout. A single forward scan with small lookaheads.
pub fn inlineMd(alloc: std.mem.Allocator, buf: *Buf, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            if (closer(text, i + 1, "`")) |j| {
                try buf.appendSlice(alloc, "<code>");
                try escape(alloc, buf, text[i + 1 .. j]);
                try buf.appendSlice(alloc, "</code>");
                i = j + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (closer(text, i + 2, "**")) |j| {
                try buf.appendSlice(alloc, "<strong>");
                try inlineMd(alloc, buf, text[i + 2 .. j]);
                try buf.appendSlice(alloc, "</strong>");
                i = j + 2;
                continue;
            }
        } else if (c == '*') {
            if (closer(text, i + 1, "*")) |j| {
                try buf.appendSlice(alloc, "<em>");
                try inlineMd(alloc, buf, text[i + 1 .. j]);
                try buf.appendSlice(alloc, "</em>");
                i = j + 1;
                continue;
            }
        } else if (c == '[') {
            if (link(text, i)) |lk| {
                try buf.appendSlice(alloc, "<a href=\"");
                try escapeAttr(alloc, buf, lk.url);
                try buf.appendSlice(alloc, "\">");
                try inlineMd(alloc, buf, lk.text);
                try buf.appendSlice(alloc, "</a>");
                i = lk.end;
                continue;
            }
        }
        try escapeChar(alloc, buf, c);
        i += 1;
    }
}

const Link = struct { text: []const u8, url: []const u8, end: usize };

/// Parse `[text](url)` starting at `[`. Returns null if not a well-formed link.
fn link(text: []const u8, start: usize) ?Link {
    const close_br = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (close_br + 1 >= text.len or text[close_br + 1] != '(') return null;
    const close_par = std.mem.indexOfScalarPos(u8, text, close_br + 2, ')') orelse return null;
    return .{ .text = text[start + 1 .. close_br], .url = text[close_br + 2 .. close_par], .end = close_par + 1 };
}

/// Index of the next occurrence of `mark` at or after `from`, or null.
fn closer(text: []const u8, from: usize, mark: []const u8) ?usize {
    if (from > text.len) return null;
    return std.mem.indexOfPos(u8, text, from, mark);
}

pub fn escape(alloc: std.mem.Allocator, buf: *Buf, text: []const u8) !void {
    for (text) |ch| try escapeChar(alloc, buf, ch);
}

fn escapeChar(alloc: std.mem.Allocator, buf: *Buf, ch: u8) !void {
    switch (ch) {
        '&' => try buf.appendSlice(alloc, "&amp;"),
        '<' => try buf.appendSlice(alloc, "&lt;"),
        '>' => try buf.appendSlice(alloc, "&gt;"),
        else => try buf.append(alloc, ch),
    }
}

fn escapeAttr(alloc: std.mem.Allocator, buf: *Buf, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try buf.appendSlice(alloc, "&amp;"),
        '<' => try buf.appendSlice(alloc, "&lt;"),
        '"' => try buf.appendSlice(alloc, "&quot;"),
        else => try buf.append(alloc, ch),
    };
}
