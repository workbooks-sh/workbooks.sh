//! site — an `index.work` `app` block → a multi-page SPA workbook: a portal-style
//! sidebar, a section/page nav tree, and our OWN History-API router (so pages can
//! carry `client` islands in any language without a framework router). The build
//! target for docs/site workbooks. Pure string-building, so it runs native + wasm.
const std = @import("std");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");
const render = @import("render.zig");

const Buf = std.ArrayList(u8);

const Item = struct { route: []const u8, title: []const u8, html: []const u8, src: []const u8 };
const Section = struct { title: []const u8, items: std.ArrayList(Item) };

/// Find the `app` unit in already-parsed index nodes; null if this isn't a site.
pub fn appBlock(nodes: []const work.Node) ?work.Node {
    for (nodes) |n| if (n.type == .code and std.mem.eql(u8, n.kind, "app")) return n;
    return null;
}

/// Build the SPA from the app spec body. `dir` is the workbook root.
pub fn build(io: Io, alloc: std.mem.Allocator, dir: []const u8, out: []const u8, app_body: []const u8) !u8 {
    var title: []const u8 = "Workbooks";
    var sections: std.ArrayList(Section) = .empty;
    var cur: ?usize = null;
    var page_count: usize = 0;

    var lines = std.mem.splitScalar(u8, app_body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "title ")) {
            if (dquoted(line)) |t| title = t;
        } else if (std.mem.startsWith(u8, line, "section ")) {
            if (dquoted(line)) |t| {
                try sections.append(alloc, .{ .title = t, .items = .empty });
                cur = sections.items.len - 1;
            }
        } else if (std.mem.startsWith(u8, line, "page ")) {
            const path = dquoted(line) orelse continue;
            const file = try std.fmt.allocPrint(alloc, "{s}/{s}.work", .{ dir, path });
            const item = try renderPage(io, alloc, file, path);
            if (cur) |i| try sections.items[i].items.append(alloc, item);
            page_count += 1;
        }
    }

    const home = firstRoute(sections.items) orelse "/";

    var buf: Buf = .empty;
    try buf.appendSlice(alloc, "<!doctype html>\n<html lang=\"en\" data-theme=\"dark\">\n<head><meta charset=\"utf-8\">\n");
    try buf.appendSlice(alloc, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try buf.appendSlice(alloc, "<meta name=\"darkreader-lock\"><meta name=\"color-scheme\" content=\"dark light\">\n<title>");
    try render.escape(alloc, &buf, title);
    try buf.appendSlice(alloc, "</title>\n<style>");
    try buf.appendSlice(alloc, css);
    try buf.appendSlice(alloc, "</style>\n</head>\n<body>\n");

    // ── sidebar ── DNA strip is full-bleed flush at the very top; everything else
    // lives in a padded, scrollable body below it.
    try buf.appendSlice(alloc, "<aside class=\"side\">\n");
    try buf.appendSlice(alloc, dnastrip);
    try buf.appendSlice(alloc, "<div class=\"sidebody\">\n<div class=\"brand\">");
    try buf.appendSlice(alloc, petal);
    try buf.appendSlice(alloc, "<b>");
    try render.escape(alloc, &buf, title);
    try buf.appendSlice(alloc, "</b>\n<span class=\"mode\">night</span></div>\n");
    try buf.appendSlice(alloc, "<input class=\"search\" type=\"search\" placeholder=\"Search\u{2026}\" aria-label=\"Search\">\n<nav>\n");
    // Each section carries one pastel from the DNA family — the "little touches".
    const pastels = [_][]const u8{ "#aee5c2", "#a8d4f0", "#f3c5a3", "#f2ddb0", "#c8e0b0", "#9fc4e8", "#d9c5f0" };
    for (sections.items, 0..) |s, si| {
        const sec = pastels[si % pastels.len];
        try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<div class=\"navsec\" style=\"--sec:{s}\">\n<div class=\"sec\"><span class=\"dot\"></span>", .{sec}));
        try render.escape(alloc, &buf, s.title);
        try buf.appendSlice(alloc, "</div>\n");
        for (s.items.items) |it| {
            try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<a class=\"nav\" data-route=\"{s}\" href=\"{s}\">", .{ it.route, it.route }));
            try render.escape(alloc, &buf, it.title);
            try buf.appendSlice(alloc, "</a>\n");
        }
        try buf.appendSlice(alloc, "</div>\n");
    }
    try buf.appendSlice(alloc, "</nav>\n<div class=\"foot\"><a href=\"https://github.com/workbooks-sh/workbooks.sh\">GitHub</a></div>\n</div>\n</aside>\n");

    // ── pages ──
    try buf.appendSlice(alloc, "<main>\n");
    for (sections.items) |s| {
        for (s.items.items) |it| {
            try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<article class=\"page\" data-route=\"{s}\">\n", .{it.route}));
            try buf.appendSlice(alloc, "<div class=\"pgbar\"><button class=\"cp\" data-copy=\"md\">Copy as Markdown</button><button class=\"cp\" data-copy=\"prompt\">Copy as prompt</button></div>\n");
            try buf.appendSlice(alloc, "<script type=\"text/markdown\" class=\"src\">");
            try render.escape(alloc, &buf, it.src);
            try buf.appendSlice(alloc, "</script>\n");
            try buf.appendSlice(alloc, it.html);
            try buf.appendSlice(alloc, "</article>\n");
        }
    }
    try buf.appendSlice(alloc, "</main>\n");

    // Agent-ergonomics: llms.txt (index) + llms-full.txt (every page source) beside the output.
    try writeLlms(io, alloc, out, title, sections.items);

    try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<script>\nconst HOME={s};\n{s}</script>\n", .{ try jsString(alloc, home), router }));
    try buf.appendSlice(alloc, "</body>\n</html>\n");

    try fs.writeFile(io, out, buf.items);
    log.ok(try std.fmt.allocPrint(alloc, "{s} \u{b7} {d} page(s) \u{b7} {d} section(s) \u{b7} {d} B \u{b7} SPA", .{ std.fs.path.basename(out), page_count, sections.items.len, buf.items.len }));
    return 0;
}

fn renderPage(io: Io, alloc: std.mem.Allocator, file: []const u8, path: []const u8) !Item {
    const route = try std.fmt.allocPrint(alloc, "/{s}", .{path});
    const src = fs.readFile(io, alloc, file) catch {
        log.warn(try std.fmt.allocPrint(alloc, "missing page: {s}", .{file}));
        return .{ .route = route, .title = path, .html = "<p class=\"missing\">(page not found)</p>", .src = "" };
    };
    const ns = try work.parse(alloc, src);
    const html = try render.nodes(alloc, ns);
    var title: []const u8 = path;
    for (ns) |n| if (n.type == .heading and n.level == 1) {
        title = n.text;
        break;
    };
    return .{ .route = route, .title = title, .html = html, .src = src };
}

fn firstRoute(sections: []const Section) ?[]const u8 {
    for (sections) |s| if (s.items.items.len > 0) return s.items.items[0].route;
    return null;
}

/// Extract the first double-quoted substring of a line, or null.
fn dquoted(line: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse return null;
    return line[a + 1 .. b];
}

/// JSON-encode a string for safe embedding in the inline script.
fn jsString(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var b: Buf = .empty;
    try b.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try b.appendSlice(alloc, "\\\""),
        '\\' => try b.appendSlice(alloc, "\\\\"),
        '<' => try b.appendSlice(alloc, "\\u003c"),
        else => try b.append(alloc, ch),
    };
    try b.append(alloc, '"');
    return b.items;
}

/// Emit llms.txt (index) and llms-full.txt (every page's source) beside `out`.
fn writeLlms(io: Io, alloc: std.mem.Allocator, out: []const u8, title: []const u8, sections: []const Section) !void {
    const dir = std.fs.path.dirname(out) orelse ".";

    var idx: Buf = .empty;
    try idx.appendSlice(alloc, try std.fmt.allocPrint(alloc, "# {s}\n\n", .{title}));
    var full: Buf = .empty;
    try full.appendSlice(alloc, try std.fmt.allocPrint(alloc, "# {s}\n\n", .{title}));

    for (sections) |s| {
        try idx.appendSlice(alloc, try std.fmt.allocPrint(alloc, "## {s}\n", .{s.title}));
        for (s.items.items) |it| {
            try idx.appendSlice(alloc, try std.fmt.allocPrint(alloc, "- [{s}]({s})\n", .{ it.title, it.route }));
            try full.appendSlice(alloc, try std.fmt.allocPrint(alloc, "## {s}  ({s})\n\n{s}\n\n---\n\n", .{ it.title, it.route, it.src }));
        }
        try idx.append(alloc, '\n');
    }

    try fs.writeFile(io, try std.fmt.allocPrint(alloc, "{s}/llms.txt", .{dir}), idx.items);
    try fs.writeFile(io, try std.fmt.allocPrint(alloc, "{s}/llms-full.txt", .{dir}), full.items);
}

// The DNA strip — our canonical full-bleed component: the pastel family in weighted
// proportions, duplicated for a seamless translateX(-50%) loop. Always full-bleed
// (no padding/margin/radius) — pinned flush at the top of a sidebar, or used as a
// full-bleed divider between sections. Matches the cloud portal.
const dnastrip =
    \\<div class="dna"><div class="dnatrack">
    \\<i style="width:7.50%;background:#f3c5a3"></i><i style="width:6.00%;background:#aee5c2"></i><i style="width:5.00%;background:#a8d4f0"></i><i style="width:6.00%;background:#f2ddb0"></i><i style="width:3.50%;background:#9fc4e8"></i><i style="width:7.50%;background:#f3c5a3"></i><i style="width:6.00%;background:#aee5c2"></i><i style="width:5.00%;background:#a8d4f0"></i><i style="width:3.50%;background:#9fc4e8"></i>
    \\<i style="width:7.50%;background:#f3c5a3"></i><i style="width:6.00%;background:#aee5c2"></i><i style="width:5.00%;background:#a8d4f0"></i><i style="width:6.00%;background:#f2ddb0"></i><i style="width:3.50%;background:#9fc4e8"></i><i style="width:7.50%;background:#f3c5a3"></i><i style="width:6.00%;background:#aee5c2"></i><i style="width:5.00%;background:#a8d4f0"></i><i style="width:3.50%;background:#9fc4e8"></i>
    \\</div></div>
;

const petal =
    \\<svg class="mark" viewBox="0 0 113.444 65.6002" fill="none" aria-hidden="true"><path fill="currentColor" d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308 65.53 10.08 65.175 19.962 65.462 29.738 65.487 30.568 65.871 31.142 66.391 31.743 72.108 33.464 84.752 13.845 90.921 11.74 93.907 12.344 100.087 19.999 102.273 22.457 98.731 28.417 83.273 40.691 81.382 45.003 81.4 46.287 81.45 46.326 82.157 47.442 83.708 48.637 108.252 47.988 113.133 48.464 113.57 53.985 113.431 59.865 113.391 65.428 101.67 65.449 86.679 66.781 76.472 61.69 68.049 57.527 61.65 50.16 58.704 41.238 57.939 38.586 57.387 36.15 56.78 33.468 55.6 38.7 54.677 42.988 51.921 47.705 39.805 68.442 20.228 65.456 0.065 65.389-0.058 59.646-0.006 53.901 0.222 48.161 5.512 48.136 28.425 48.742 31.699 47.27 31.862 46.897 31.905 46.848 31.987 46.404 32.672 42.681 14.558 27.349 11.618 22.838L11.373 22.456C13.177 19.907 19.347 13.073 22.063 11.774 25.791 11.211 40.002 29.83 44.456 31.689 45.845 32.268 46.068 32.231 47.291 31.751 48.666 29.798 48.206 22.821 48.217 20.153L48.271 0.137Z"/></svg>
;

const router =
    \\function route(p){
    \\  let hit=false;
    \\  document.querySelectorAll('article.page').forEach(a=>{const on=a.dataset.route===p;a.style.display=on?'block':'none';if(on)hit=true;});
    \\  if(!hit){document.querySelectorAll('article.page').forEach((a,i)=>a.style.display=i===0?'block':'none');p=document.querySelector('article.page')?.dataset.route||p;}
    \\  document.querySelectorAll('a.nav').forEach(n=>n.classList.toggle('on',n.dataset.route===p));
    \\  const t=document.querySelector('a.nav.on');if(t)document.title=t.textContent+' — Workbooks';
    \\  window.scrollTo(0,0);
    \\}
    \\document.addEventListener('click',e=>{const a=e.target.closest('a[href^="/"]');if(!a)return;const r=a.dataset.route||a.getAttribute('href');e.preventDefault();history.pushState({},'',r);route(r);});
    \\window.addEventListener('popstate',()=>route(location.pathname));
    \\const sb=document.querySelector('.search');
    \\if(sb)sb.addEventListener('input',()=>{const q=sb.value.toLowerCase();document.querySelectorAll('a.nav').forEach(n=>{n.style.display=n.textContent.toLowerCase().includes(q)?'block':'none';});});
    \\document.addEventListener('click',async e=>{const b=e.target.closest('.cp');if(!b)return;const art=b.closest('article.page');const md=art.querySelector('script.src')?.textContent||'';const title=art.querySelector('h1')?.textContent||'this page';const text=b.dataset.copy==='prompt'?('Using the Workbooks documentation below, help me with '+title+'.\n\n'+md):md;try{await navigator.clipboard.writeText(text);const o=b.textContent;b.textContent='Copied';setTimeout(()=>b.textContent=o,1200);}catch(_){}});
    \\route(location.pathname&&location.pathname!=='/'?location.pathname:HOME);
;

const css =
    \\:root{--paper:#f7f6f1;--card:#fff;--ink:#1a1b1e;--dim:#6a6f68;--line:#e7e5db;--pc:#a8d4f0;--pcd:#2f6fa8;--hover:rgba(18,19,22,.05);--sec:#aee5c2}
    \\html[data-theme=dark]{--paper:#16171a;--card:#1f2125;--ink:#ecebe5;--dim:#8c9189;--line:#2d2f34;--pcd:#a8d4f0;--hover:rgba(255,255,255,.05)}
    \\*{box-sizing:border-box}body{margin:0;display:flex;min-height:100vh;background:var(--paper);color:var(--ink);font:16px/1.65 'Geist',ui-sans-serif,system-ui,sans-serif}
    \\.side{width:266px;flex:none;border-right:1px solid var(--line);position:sticky;top:0;height:100vh;display:flex;flex-direction:column;overflow:hidden}
    \\.sidebody{padding:14px 14px 18px;display:flex;flex-direction:column;gap:12px;flex:1;min-height:0;overflow-y:auto}
    \\.dna{height:8px;overflow:hidden;flex:none}.dnatrack{display:flex;height:100%;width:200%;animation:drift 52s linear infinite}.dnatrack i{display:block;height:100%}
    \\@keyframes drift{to{transform:translateX(-50%)}}@media(prefers-reduced-motion:reduce){.dnatrack{animation:none}}
    \\.brand{display:flex;align-items:center;gap:9px}.brand .mark{width:26px;height:auto;color:var(--ink)}.brand b{font-weight:650;flex:1}
    \\.mode{font:600 10px 'Geist Mono',monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--dim)}
    \\.search{width:100%;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);font:inherit;font-size:14px}
    \\nav{display:flex;flex-direction:column;flex:1}.navsec{display:flex;flex-direction:column;gap:1px}
    \\.sec{display:flex;align-items:center;gap:7px;font:600 11px 'Geist Mono',monospace;letter-spacing:.08em;text-transform:uppercase;color:var(--dim);margin:16px 0 5px;padding:0 8px}
    \\.sec .dot{width:8px;height:8px;border-radius:50%;background:var(--sec);flex:none}
    \\a.nav{display:block;padding:6px 9px;border-radius:7px;color:var(--ink);text-decoration:none;font-size:14.5px;box-shadow:inset 0 0 0 0 var(--sec)}
    \\a.nav:hover{background:var(--hover)}a.nav.on{background:var(--hover);font-weight:600;box-shadow:inset 3px 0 0 var(--sec)}
    \\.foot{border-top:1px solid var(--line);padding-top:10px;margin-top:6px;font-size:13px}.foot a{color:var(--dim);text-decoration:none}.foot a:hover{color:var(--ink)}
    \\main{flex:1;min-width:0;display:flex;justify-content:center;padding:56px 32px 140px}
    \\article{max-width:46rem;width:100%;display:none}
    \\.pgbar{display:flex;gap:8px;justify-content:flex-end;margin-bottom:6px}
    \\.cp{font:12px 'Geist Mono',monospace;color:var(--dim);background:var(--card);border:1px solid var(--line);border-radius:7px;padding:4px 9px;cursor:pointer}
    \\.cp:hover{color:var(--ink);border-color:var(--dim)}
    \\script.src{display:none}
    \\h1{font-size:30px;letter-spacing:-.02em;margin:0 0 .5em}h2{font-size:21px;margin:1.7em 0 .5em}h3{font-size:17px;margin:1.4em 0 .4em}
    \\p{margin:.75em 0}a{color:var(--pcd)}
    \\ul{margin:.6em 0;padding-left:1.3em}li{margin:.25em 0}
    \\code{font:13.5px 'Geist Mono',ui-monospace,monospace;background:rgba(127,127,127,.14);padding:.1em .35em;border-radius:4px}
    \\figure.unit{margin:1.2em 0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:var(--card)}
    \\figure.unit figcaption{display:flex;gap:.5em;align-items:center;padding:8px 13px;border-bottom:1px solid var(--line);font:12px 'Geist Mono',monospace}
    \\figcaption .kind{background:var(--ink);color:var(--paper);padding:.1em .5em;border-radius:5px;text-transform:uppercase;letter-spacing:.05em;font-size:10.5px}
    \\figcaption .lang{color:var(--dim)}figcaption .nm{color:var(--ink);font-weight:600}
    \\figure.unit pre{margin:0;padding:13px 15px;overflow:auto}figure.unit pre code{background:none;padding:0;display:block;white-space:pre;line-height:1.55}
    \\.missing{color:#b00}
    \\@media(max-width:760px){body{flex-direction:column}.side{width:auto;height:auto;position:static;border-right:0;border-bottom:1px solid var(--line)}main{padding:32px 20px 80px}}
;
