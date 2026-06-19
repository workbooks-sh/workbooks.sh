//! weave — a `.work` tree → ONE self-contained HTML. If `index.work` declares an
//! `app` block it builds a multi-page SPA with a sidebar + our own router (see
//! site.zig); otherwise it concatenates the files into one scrolling document.
//! The document IS the render — prose is markdown, `client` blocks are emitted
//! verbatim, other units render as labelled source figures (see render.zig). Pure
//! string-building over the parser, so it runs native + in the wasm sandbox.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");
const render = @import("render.zig");
const site = @import("site.zig");

const Buf = std.ArrayList(u8);

pub fn weave(io: Io, alloc: std.mem.Allocator, dir: []const u8, out: []const u8) !u8 {
    log.prompt(try std.fmt.allocPrint(alloc, "work weave {s} \u{2192} {s}", .{ dir, out }));

    // Site mode: index.work declares an `app` block → a multi-page SPA.
    const index_path = try std.fmt.allocPrint(alloc, "{s}/index.work", .{dir});
    if (fs.readFile(io, alloc, index_path)) |index_src| {
        const index_nodes = try work.parse(alloc, index_src);
        if (site.appBlock(index_nodes)) |app| return site.build(io, alloc, dir, out, app.body);
    } else |_| {}

    // Single-document mode: every file as a section in one scrolling page.
    const files = try fs.workFiles(io, alloc, dir);
    var title: []const u8 = std.fs.path.basename(dir);
    var units: usize = 0;

    var body: Buf = .empty;
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| if (n.type == .heading and n.level == 1 and std.mem.eql(u8, title, std.fs.path.basename(dir))) {
            title = n.text;
        } else if (n.type == .code) {
            units += 1;
        };
        try body.appendSlice(alloc, "<section class=\"page\">\n");
        try body.appendSlice(alloc, try render.nodes(alloc, nodes));
        try body.appendSlice(alloc, "</section>\n");
    }

    var buf: Buf = .empty;
    try buf.appendSlice(alloc, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try render.escape(alloc, &buf, title);
    try buf.appendSlice(alloc, "</title>\n<style>");
    try buf.appendSlice(alloc, css);
    try buf.appendSlice(alloc, "</style>\n</head><body>\n<main class=\"wb\">\n");
    try buf.appendSlice(alloc, body.items);
    try buf.appendSlice(alloc, "</main>\n</body></html>\n");

    try fs.writeFile(io, out, buf.items);
    log.ok(try std.fmt.allocPrint(alloc, "{s} \u{b7} {d} unit(s) \u{b7} {d} B \u{b7} static", .{ std.fs.path.basename(out), units, buf.items.len }));
    return 0;
}

const css =
    \\:root{--paper:#fbfaf3;--ink:#121316;--line:#e6e3d8;--mut:#6b7382;--mint:#aee5c2;--card:#fff}
    \\*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.65 'Geist',ui-sans-serif,system-ui,sans-serif}
    \\.wb{max-width:46rem;margin:0 auto;padding:56px 24px 120px}h1{font-size:30px;letter-spacing:-.02em}h2{font-size:21px;margin-top:1.5em}h3{font-size:17px}
    \\p{margin:.75em 0}a{color:#2f6f4f}ul{margin:.6em 0;padding-left:1.3em}
    \\code{font:13.5px 'Geist Mono',ui-monospace,monospace;background:rgba(127,127,127,.14);padding:.1em .35em;border-radius:4px}
    \\figure.unit{margin:1.2em 0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:var(--card)}
    \\figure.unit figcaption{display:flex;gap:.5em;align-items:center;padding:8px 13px;border-bottom:1px solid var(--line);font:12px 'Geist Mono',monospace}
    \\figcaption .kind{background:var(--ink);color:var(--paper);padding:.1em .5em;border-radius:5px;text-transform:uppercase;letter-spacing:.05em;font-size:10.5px}
    \\figcaption .lang{color:var(--mut)}figcaption .nm{color:var(--ink);font-weight:600}
    \\figure.unit pre{margin:0;padding:13px 15px;overflow:auto}figure.unit pre code{background:none;padding:0;display:block;white-space:pre;line-height:1.55}
;
