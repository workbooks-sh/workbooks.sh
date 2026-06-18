//! weave — a `.work` tree → ONE self-contained HTML workbook. Prose renders to HTML; each unit
//! becomes a `<work-component>` carrying its source (on-canon: a workbook IS HTML built from work-*
//! elements). The static floor — renders in any browser, no engine. Pure string-building over the
//! parser, so it runs native + in the wasm sandbox.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

pub fn weave(io: Io, alloc: std.mem.Allocator, dir: []const u8, out: []const u8) !u8 {
    const files = try fs.workFiles(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work weave {s} \u{2192} {s}", .{ dir, out }));

    var buf: std.ArrayList(u8) = .empty;
    var title: []const u8 = std.fs.path.basename(dir);
    var units: usize = 0;

    var body: std.ArrayList(u8) = .empty;
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        try body.appendSlice(alloc, "<section class=\"page\">\n");
        for (nodes) |n| switch (n.type) {
            .heading => {
                if (n.level == 1 and std.mem.eql(u8, title, std.fs.path.basename(dir))) title = n.text;
                try body.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<h{d}>", .{n.level}));
                try escape(alloc, &body, n.text);
                try body.appendSlice(alloc, try std.fmt.allocPrint(alloc, "</h{d}>\n", .{n.level}));
            },
            .prose => {
                try body.appendSlice(alloc, "<p>");
                try escape(alloc, &body, n.text);
                try body.appendSlice(alloc, "</p>\n");
            },
            .code => {
                units += 1;
                try body.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<work-component lang=\"{s}\" name=\"{s}\" kind=\"{s}\">", .{ n.lang, n.name, n.kind }));
                try body.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<header class=\"unit\"><span class=\"nm\">:{s}</span><span class=\"kn\">{s} {s}</span></header><pre class=\"src\"><code>", .{ n.name, n.kind, n.lang }));
                try escape(alloc, &body, n.header);
                try body.appendSlice(alloc, " do\n");
                try escape(alloc, &body, n.body);
                try body.appendSlice(alloc, "\nend</code></pre></work-component>\n");
            },
        };
        try body.appendSlice(alloc, "</section>\n");
    }

    try buf.appendSlice(alloc, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try escape(alloc, &buf, title);
    try buf.appendSlice(alloc, "</title>\n<style>");
    try buf.appendSlice(alloc, css);
    try buf.appendSlice(alloc, "</style>\n</head><body>\n<main class=\"wb\">\n");
    try buf.appendSlice(alloc, body.items);
    try buf.appendSlice(alloc, "</main>\n</body></html>\n");

    try fs.writeFile(io, out, buf.items);

    log.ok(try std.fmt.allocPrint(alloc, "{s} \u{b7} {d} unit(s) \u{b7} {d} B \u{b7} static", .{ std.fs.path.basename(out), units, buf.items.len }));
    log.step("dynamic hydration (compile + live data) needs a nexus");
    return 0;
}

fn escape(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try buf.appendSlice(alloc, "&amp;"),
        '<' => try buf.appendSlice(alloc, "&lt;"),
        '>' => try buf.appendSlice(alloc, "&gt;"),
        else => try buf.append(alloc, ch),
    };
}

const css =
    \\:root{--paper:#fbfaf3;--ink:#121316;--line:#e6e3d8;--mut:#6b7382;--mint:#aee5c2}
    \\*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.6 ui-sans-serif,system-ui,'Geist',sans-serif}
    \\.wb{max-width:780px;margin:0 auto;padding:56px 24px 120px}h1{font-size:30px;letter-spacing:-.02em}h2{font-size:22px;margin-top:1.4em}
    \\p{margin:.7em 0}code{font:13px 'Geist Mono',ui-monospace,monospace;background:rgba(18,19,22,.05);padding:.1em .3em;border-radius:4px}
    \\work-component{display:block;margin:18px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:#fff}
    \\.unit{display:flex;justify-content:space-between;padding:9px 14px;border-bottom:1px solid var(--line);background:#fcfbf6}
    \\.unit .nm{font:600 13px 'Geist Mono',monospace}.unit .kn{font:11px 'Geist Mono',monospace;color:var(--mut);text-transform:uppercase;letter-spacing:.06em}
    \\pre.src{margin:0;padding:14px;overflow:auto}pre.src code{background:none;padding:0;display:block;white-space:pre}
;
