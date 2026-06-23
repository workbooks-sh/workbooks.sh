//! The `.work` literate parser — the ONE toolchain core, in Zig (native + wasm). A `.work` file is
//! prose + `<kind> [lang] :name … do … end` unit blocks. Parsing yields a flat node list the verbs
//! (check/structure/why/near/wit) and the weaver read. Pure: a source string in, nodes out — no I/O,
//! so it runs identically on a laptop and inside the agent's wasm sandbox.
const std = @import("std");

pub const NodeType = enum { heading, code, prose, note };

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
    // hash-note lane: `+`/`-` for a live note (0 for a collapsed handle), and the
    // `≡<hash>` handle's sweep-sha. Notes are STRIPPED from the woven artifact.
    note_marker: u8 = 0,
    collapsed: bool = false,
    hash: []const u8 = "",
};

// MUST match the nexus `Nexus.Literate` @langs set exactly (zero parser drift).
const langs = [_][]const u8{ "elixir", "rust", "zig", "c", "cpp", "js", "ts", "python", "go", "svelte", "solid", "wit" };

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

        if (noteNode(line)) |nt| {
            try flushProse(alloc, &prose, &nodes);
            try nodes.append(alloc, nt);
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

// A hash note: `+# …` pinned, `-# …` drawered, or a `≡<hash> …` collapsed handle.
// Leading whitespace is allowed (notes nest). MUST mirror the nexus `Nexus.Literate`
// note lane (zero parser drift). Notes are dropped from the woven artifact by render.
const handle = "\u{2261}"; // ≡  (U+2261 IDENTICAL TO)

fn noteNode(line: []const u8) ?Node {
    const s = std.mem.trimStart(u8, line, " \t");
    if (s.len >= 2 and (s[0] == '+' or s[0] == '-') and s[1] == '#') {
        return Node{ .type = .note, .note_marker = s[0], .text = std.mem.trim(u8, s[2..], " \t\r") };
    }
    if (std.mem.startsWith(u8, s, handle)) {
        const rest = std.mem.trim(u8, s[handle.len..], " \t\r");
        var j: usize = 0;
        while (j < rest.len and isWord(rest[j])) j += 1;
        return Node{ .type = .note, .collapsed = true, .hash = rest[0..j], .text = std.mem.trim(u8, rest[j..], " \t\r") };
    }
    return null;
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

// Inline-reference extraction. MUST stay in lockstep with the Elixir reference parser's `@ref_re`
// (nexus `Nexus.Literate`): the SAME five token classes, as FULL-MATCH strings, so the cross-language
// conformance golden (corpus/refs.golden) matches both. Tokens inside `inline code` are syntax
// examples, not refs, and are skipped. The five kinds:
//   [[backlink]]   — `\[\[[^\]\n]+\]\]`                       (kept with brackets)
//   work://url     — `work:\/\/[^\s)]*[a-zA-Z0-9_\/#-]`       (must end on a url char)
//   :atom          — `(?<![\w:]):[a-z]\w*`                    (`:` not after word-char or `:`)
//   @type          — `(?<![\w])@[a-z]\w*`
//   #tag           — `(?<![\w])#[a-z][\w-]*`
pub fn extractRefs(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const prev: ?u8 = if (i > 0) text[i - 1] else null;

        if (c == '`') {
            // inline `code` is a syntax EXAMPLE, not a real reference — skip the span.
            i = (std.mem.indexOfPos(u8, text, i + 1, "`") orelse text.len - 1) + 1;
            continue;
        }

        // [[backlink]] — full match incl brackets, no `]` or newline inside.
        if (c == '[' and i + 1 < text.len and text[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, text, i + 2, "]]")) |close| {
                const inner = text[i + 2 .. close];
                if (inner.len > 0 and std.mem.indexOfScalar(u8, inner, '\n') == null and std.mem.indexOfScalar(u8, inner, ']') == null) {
                    try refs.append(alloc, text[i .. close + 2]);
                    i = close + 2;
                    continue;
                }
            }
        }

        // work://… — ends on the last [a-zA-Z0-9_/#-] before whitespace/`)`.
        if (c == 'w' and std.mem.startsWith(u8, text[i..], "work://")) {
            var j = i + "work://".len;
            while (j < text.len and text[j] != ' ' and text[j] != '\t' and text[j] != '\n' and text[j] != '\r' and text[j] != ')') j += 1;
            while (j > i + "work://".len and !isUrlEnd(text[j - 1])) j -= 1;
            if (j > i + "work://".len) {
                try refs.append(alloc, text[i..j]);
                i = j;
                continue;
            }
        }

        // :atom — `:` not preceded by a word char or another `:`, then [a-z]\w*
        if (c == ':' and notWord(prev) and prev != ':' and i + 1 < text.len and isLowerAlpha(text[i + 1])) {
            var j = i + 1;
            while (j < text.len and isWord(text[j])) j += 1;
            try refs.append(alloc, text[i..j]);
            i = j;
            continue;
        }

        // @type — `@` not preceded by a word char, then [a-z]\w*
        if (c == '@' and notWord(prev) and i + 1 < text.len and isLowerAlpha(text[i + 1])) {
            var j = i + 1;
            while (j < text.len and isWord(text[j])) j += 1;
            try refs.append(alloc, text[i..j]);
            i = j;
            continue;
        }

        // #tag — `#` not preceded by a word char, then [a-z][\w-]*
        if (c == '#' and notWord(prev) and i + 1 < text.len and isLowerAlpha(text[i + 1])) {
            var j = i + 1;
            while (j < text.len and (isWord(text[j]) or text[j] == '-')) j += 1;
            try refs.append(alloc, text[i..j]);
            i = j;
            continue;
        }

        i += 1;
    }
    return refs.toOwnedSlice(alloc);
}

inline fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}
inline fn notWord(c: ?u8) bool {
    return if (c) |ch| !isWord(ch) else true;
}
inline fn isLowerAlpha(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
inline fn isUrlEnd(c: u8) bool {
    return isWord(c) or c == '/' or c == '#' or c == '-';
}

/// The inner label of a `[[backlink]]` token, or null for any other ref kind. Code-graph edges and
/// `check` resolution use ONLY backlinks (the resolvable references); :atom/@type/#tag/work:// are
/// other ref classes the parser still captures (parity with the nexus) but check does not resolve.
pub fn backlinkLabel(ref: []const u8) ?[]const u8 {
    if (ref.len >= 4 and std.mem.startsWith(u8, ref, "[[") and std.mem.endsWith(u8, ref, "]]"))
        return ref[2 .. ref.len - 2];
    return null;
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
    try std.testing.expectEqualStrings("[[pricing]]", nodes[1].refs[0]); // full match, parity w/ nexus
    try std.testing.expectEqualStrings("pricing", backlinkLabel(nodes[1].refs[0]).?);
    try std.testing.expectEqual(NodeType.code, nodes[2].type);
    try std.testing.expectEqualStrings("sandbox", nodes[2].kind);
    try std.testing.expectEqualStrings("rust", nodes[2].lang);
    try std.testing.expectEqualStrings("pricing", nodes[2].name);
}

test "recognizes hash notes (+#/-#/≡hash) as a stripped lane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = "# Store\n+# pinned: guest shim next\n  -# dropped krunvm here\n\u{2261}a3f9 why we dropped the sidecar";
    const nodes = try parse(a, real);
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqual(NodeType.note, nodes[1].type);
    try std.testing.expectEqual(@as(u8, '+'), nodes[1].note_marker);
    try std.testing.expectEqualStrings("pinned: guest shim next", nodes[1].text);
    try std.testing.expectEqual(NodeType.note, nodes[2].type);
    try std.testing.expectEqual(@as(u8, '-'), nodes[2].note_marker);
    try std.testing.expectEqual(NodeType.note, nodes[3].type);
    try std.testing.expect(nodes[3].collapsed);
    try std.testing.expectEqualStrings("a3f9", nodes[3].hash);
}
