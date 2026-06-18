//! The `.work` literate parser — the ONE toolchain core, in Zig (native + wasm). A `.work` file is
//! prose + `<kind> [lang] :name … do … end` unit blocks. Parsing yields a flat node list the verbs
//! (check/structure/why/near/wit) and the weaver read. Pure: a source string in, nodes out — no I/O,
//! so it runs identically on a laptop and inside the agent's wasm sandbox.
const std = @import("std");

pub const NodeType = enum { heading, code, prose };

pub const Node = struct {
    type: NodeType,
    level: u8 = 0,
    kind: []const u8 = "",
    lang: []const u8 = "",
    name: []const u8 = "",
    header: []const u8 = "",
    body: []const u8 = "",
    text: []const u8 = "",
    refs: []const []const u8 = &.{},
};

const langs = [_][]const u8{ "elixir", "rust", "zig", "c", "cpp", "js", "ts", "python", "go", "svelte", "solid" };

pub fn parse(alloc: std.mem.Allocator, src: []const u8) ![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    var prose: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) {
            try flushProse(alloc, &prose, &nodes);
            continue;
        }

        if (heading(line)) |h| {
            try flushProse(alloc, &prose, &nodes);
            try nodes.append(alloc, h);
            continue;
        }

        if (isOpener(line)) {
            try flushProse(alloc, &prose, &nodes);
            const body = collectBody(&lines);
            try nodes.append(alloc, try codeNode(alloc, line, body));
            continue;
        }

        try prose.append(alloc, line);
    }
    try flushProse(alloc, &prose, &nodes);
    return nodes.toOwnedSlice(alloc);
}

fn heading(line: []const u8) ?Node {
    if (line.len == 0 or line[0] != '#') return null;
    var i: usize = 0;
    while (i < line.len and line[i] == '#') i += 1;
    if (i >= line.len or line[i] != ' ') return null;
    const text = std.mem.trim(u8, line[i..], " \t\r");
    return Node{ .type = .heading, .level = @intCast(@min(i, 6)), .text = text };
}

// A unit opens with a non-indented line ending in " do" (prose never ends in " do").
fn isOpener(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') return false;
    const t = std.mem.trimEnd(u8, line, " \t\r");
    return std.mem.endsWith(u8, t, " do");
}

// Collect lines until the matching non-indented `end`, tracking nested do/end depth.
fn collectBody(lines: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    const start = lines.index orelse lines.buffer.len;
    var depth: usize = 1;
    var end_at: usize = lines.buffer.len;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t\r"), " do")) depth += 1;
        if (std.mem.eql(u8, t, "end")) {
            depth -= 1;
            if (depth == 0) {
                // body is everything between start and the line before this `end`
                const body_end = (lines.index orelse lines.buffer.len) - line.len - 1;
                end_at = if (body_end > start) body_end else start;
                break;
            }
        }
    }
    return std.mem.trim(u8, lines.buffer[start..@min(end_at, lines.buffer.len)], "\n");
}

fn codeNode(alloc: std.mem.Allocator, opener: []const u8, body: []const u8) !Node {
    const header = std.mem.trimEnd(u8, std.mem.trimEnd(u8, opener, " \t\r")[0 .. std.mem.trimEnd(u8, opener, " \t\r").len - 3], " \t\r");

    var kind: []const u8 = "";
    var lang: []const u8 = "";
    var name: []const u8 = "";

    var toks = std.mem.tokenizeAny(u8, header, " \t");
    if (toks.next()) |first| kind = first;
    while (toks.next()) |tok| {
        if (tok[0] == ':') {
            name = tok[1..];
        } else if (isLang(tok) and lang.len == 0) {
            lang = tok;
        } else if (name.len == 0) {
            name = tok; // `defmodule Workbook` — the bare name
        }
    }

    return Node{
        .type = .code,
        .kind = kind,
        .lang = lang,
        .name = std.mem.trim(u8, name, ",(){}: \t"),
        .header = header,
        .body = body,
        .refs = try extractRefs(alloc, try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ header, body })),
    };
}

fn isLang(tok: []const u8) bool {
    for (langs) |l| if (std.mem.eql(u8, tok, l)) return true;
    return false;
}

fn flushProse(alloc: std.mem.Allocator, prose: *std.ArrayList([]const u8), nodes: *std.ArrayList(Node)) !void {
    if (prose.items.len == 0) return;
    const text = try std.mem.join(alloc, "\n", prose.items);
    try nodes.append(alloc, Node{ .type = .prose, .text = text, .refs = try extractRefs(alloc, text) });
    prose.clearRetainingCapacity();
}

// [[backlink]] tokens (skipping inline `code` is a later refinement).
pub fn extractRefs(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            // inline `code` is a syntax EXAMPLE, not a real reference — skip the span.
            i = (std.mem.indexOfPos(u8, text, i + 1, "`") orelse text.len - 1) + 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '[' and text[i + 1] == '[') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "]]") orelse break;
            const label = text[i + 2 .. close];
            if (std.mem.indexOfScalar(u8, label, '\n') == null and label.len > 0) {
                try refs.append(alloc, label);
            }
            i = close + 2;
            continue;
        }
        i += 1;
    }
    return refs.toOwnedSlice(alloc);
}

test "parses headings, units (kind/lang/name), prose + refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\# Store
        \\
        \\The catalog. See [[pricing]].
        \\
        \\sandbox rust :pricing do
        \\  pub fn total(n: u32) -> u32 { n * 2 }
        \\end
    ;
    const nodes = try parse(a, src);
    try std.testing.expect(nodes.len == 3);
    try std.testing.expectEqual(NodeType.heading, nodes[0].type);
    try std.testing.expectEqualStrings("Store", nodes[0].text);
    try std.testing.expectEqual(NodeType.prose, nodes[1].type);
    try std.testing.expectEqual(@as(usize, 1), nodes[1].refs.len);
    try std.testing.expectEqualStrings("pricing", nodes[1].refs[0]);
    try std.testing.expectEqual(NodeType.code, nodes[2].type);
    try std.testing.expectEqualStrings("sandbox", nodes[2].kind);
    try std.testing.expectEqualStrings("rust", nodes[2].lang);
    try std.testing.expectEqualStrings("pricing", nodes[2].name);
}
