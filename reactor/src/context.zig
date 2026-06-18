//! The CLI context — the kubectl-style mechanism that makes `work` one tool over many backends. A
//! context names a target: which nexus (URL), org, workspace. Stored at `~/.work/context.html` as a
//! `<work-context>` element (HTML, no JSON, on-canon). Every client verb (deploy verify, dev hot-swap)
//! resolves the active target through here.
const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const log = @import("log.zig");

pub const Target = struct { name: []const u8, nexus: []const u8 = "", org: []const u8 = "", workspace: []const u8 = "" };
pub const Context = struct { active: []const u8 = "local", targets: []Target = &.{} };

fn ctxPath(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ home, ".work", "context.html" });
}

pub fn load(io: Io, alloc: std.mem.Allocator, home: []const u8) !Context {
    const html = fs.readFile(io, alloc, try ctxPath(alloc, home)) catch return defaultCtx(alloc);
    return parse(alloc, html);
}

fn defaultCtx(alloc: std.mem.Allocator) !Context {
    const t = try alloc.alloc(Target, 1);
    t[0] = .{ .name = "local", .nexus = "http://localhost:4000" };
    return .{ .active = "local", .targets = t };
}

fn elemAttr(region: []const u8, name: []const u8) []const u8 {
    var pat: [48]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "{s}=\"", .{name}) catch return "";
    const at = std.mem.indexOf(u8, region, p) orelse return "";
    const vs = at + p.len;
    const ve = std.mem.indexOfScalarPos(u8, region, vs, '"') orelse return "";
    return region[vs..ve];
}

fn parse(alloc: std.mem.Allocator, html: []const u8) !Context {
    var active: []const u8 = "local";
    if (std.mem.indexOf(u8, html, "<work-context")) |c| {
        const end = std.mem.indexOfScalarPos(u8, html, c, '>') orelse html.len;
        const a = elemAttr(html[c..end], "active");
        if (a.len > 0) active = a;
    }

    var targets: std.ArrayList(Target) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "<work-target")) |t| {
        const end = std.mem.indexOfScalarPos(u8, html, t, '>') orelse html.len;
        const region = html[t..@min(end, html.len)];
        try targets.append(alloc, .{
            .name = elemAttr(region, "name"),
            .nexus = elemAttr(region, "nexus"),
            .org = elemAttr(region, "org"),
            .workspace = elemAttr(region, "workspace"),
        });
        i = end;
    }
    if (targets.items.len == 0) return defaultCtx(alloc);
    return .{ .active = active, .targets = try targets.toOwnedSlice(alloc) };
}

fn save(io: Io, alloc: std.mem.Allocator, home: []const u8, ctx: Context) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "<work-context active=\"{s}\">\n", .{ctx.active}));
    for (ctx.targets) |t| {
        try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  <work-target name=\"{s}\"", .{t.name}));
        if (t.nexus.len > 0) try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, " nexus=\"{s}\"", .{t.nexus}));
        if (t.org.len > 0) try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, " org=\"{s}\"", .{t.org}));
        if (t.workspace.len > 0) try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, " workspace=\"{s}\"", .{t.workspace}));
        try buf.appendSlice(alloc, "></work-target>\n");
    }
    try buf.appendSlice(alloc, "</work-context>\n");

    Io.Dir.cwd().createDirPath(io, try std.fs.path.join(alloc, &.{ home, ".work" })) catch {};
    try fs.writeFile(io, try ctxPath(alloc, home), buf.items);
}

pub fn nexusUrl(io: Io, alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    const ctx = try load(io, alloc, home);
    for (ctx.targets) |t| if (std.mem.eql(u8, t.name, ctx.active)) return if (t.nexus.len > 0) t.nexus else "http://localhost:4000";
    return "http://localhost:4000";
}

// ── verbs ───────────────────────────────────────────────────────────────────────────────────
pub fn ctxList(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const ctx = try load(io, alloc, home);
    log.prompt("work ctx");
    for (ctx.targets) |t| {
        const mark = if (std.mem.eql(u8, t.name, ctx.active)) "\u{25cf}" else "\u{25cb}";
        log.print("{s} {s}{s}{s}  {s}{s}{s}\n", .{ mark, log.cmd_c, t.name, log.reset, log.dim_c, t.nexus, log.reset });
    }
    return 0;
}

pub fn ctxSet(io: Io, alloc: std.mem.Allocator, home: []const u8, name: []const u8, nexus: []const u8, org: []const u8, ws: []const u8) !u8 {
    var ctx = try load(io, alloc, home);
    log.prompt(try std.fmt.allocPrint(alloc, "work ctx set {s}", .{name}));

    var list: std.ArrayList(Target) = .empty;
    var found = false;
    for (ctx.targets) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            found = true;
            try list.append(alloc, .{ .name = name, .nexus = pick(nexus, t.nexus), .org = pick(org, t.org), .workspace = pick(ws, t.workspace) });
        } else try list.append(alloc, t);
    }
    if (!found) try list.append(alloc, .{ .name = name, .nexus = nexus, .org = org, .workspace = ws });
    ctx.active = name;
    ctx.targets = try list.toOwnedSlice(alloc);
    try save(io, alloc, home, ctx);
    log.ok(try std.fmt.allocPrint(alloc, "context {s} active", .{name}));
    return 0;
}

pub fn ctxUse(io: Io, alloc: std.mem.Allocator, home: []const u8, name: []const u8) !u8 {
    var ctx = try load(io, alloc, home);
    log.prompt(try std.fmt.allocPrint(alloc, "work ctx use {s}", .{name}));
    for (ctx.targets) |t| if (std.mem.eql(u8, t.name, name)) {
        ctx.active = name;
        try save(io, alloc, home, ctx);
        log.ok(try std.fmt.allocPrint(alloc, "active context: {s}", .{name}));
        return 0;
    };
    log.err(try std.fmt.allocPrint(alloc, "no context named {s} \u{2014} `work ctx set {s} --nexus <url>`", .{ name, name }));
    return 1;
}

pub fn nexusVerb(io: Io, alloc: std.mem.Allocator, home: []const u8, url: []const u8) !u8 {
    const ctx = try load(io, alloc, home);
    return ctxSet(io, alloc, home, ctx.active, url, "", "");
}

pub fn whoami(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const ctx = try load(io, alloc, home);
    log.prompt("work whoami");
    log.ok(try std.fmt.allocPrint(alloc, "{s}", .{ctx.active}));
    for (ctx.targets) |t| if (std.mem.eql(u8, t.name, ctx.active)) {
        log.step(try std.fmt.allocPrint(alloc, "nexus {s}", .{t.nexus}));
        if (t.org.len > 0) log.step(try std.fmt.allocPrint(alloc, "org {s} \u{b7} workspace {s}", .{ t.org, t.workspace }));
    };
    if (identity(io, alloc, home)) |who| log.step(try std.fmt.allocPrint(alloc, "identity {s}", .{who}))
    else log.step("not logged in \u{2014} `work login` for the control plane");
    return 0;
}

fn pick(new: []const u8, old: []const u8) []const u8 {
    return if (new.len > 0) new else old;
}

// ── login / identity (credential at ~/.work/credentials, the control-plane token) ────────────
fn credPath(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ home, ".work", "credentials" });
}

pub fn login(io: Io, alloc: std.mem.Allocator, home: []const u8, url_in: []const u8, token: []const u8) !u8 {
    const url = if (url_in.len > 0) url_in else "https://api.workbooks.sh";
    log.prompt(try std.fmt.allocPrint(alloc, "work login {s}", .{url}));

    if (token.len > 0) {
        Io.Dir.cwd().createDirPath(io, try std.fs.path.join(alloc, &.{ home, ".work" })) catch {};
        try fs.writeFile(io, try credPath(alloc, home), try std.fmt.allocPrint(alloc, "{s}\t{s}\n", .{ url, token }));
        log.ok(try std.fmt.allocPrint(alloc, "logged in \u{b7} {s}", .{url}));
        return 0;
    }
    log.step(try std.fmt.allocPrint(alloc, "visit {s}/device to authorize, then re-run with --token <t>", .{url}));
    return 1;
}

pub fn identity(io: Io, alloc: std.mem.Allocator, home: []const u8) ?[]const u8 {
    const data = fs.readFile(io, alloc, credPath(alloc, home) catch return null) catch return null;
    const tab = std.mem.indexOfScalar(u8, data, '\t') orelse return null;
    return data[0..tab];
}
