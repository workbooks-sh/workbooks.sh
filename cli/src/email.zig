//! `work email …` — the agent + human surface for agent email. Drives the running nexus's
//! `/api/email/*` endpoints with the stored personal-access token (`work login`), the same way
//! `work cloud …` drives `/api/cloud/*`. Outbound goes through the configured relay (SMTP2GO/…);
//! inbox/read/reply hit the tenant's inbox (Cloudflare Email Routing → the ingress fills it).
//!
//!   work email send --to a@b.com --subject "Hi" --body "text"
//!   work email inbox                       (alias: list)
//!   work email read <id>
//!   work email reply <id> --body "text"
const std = @import("std");
const Io = std.Io;
const cloud = @import("cloud.zig");
const context = @import("context.zig");
const log = @import("log.zig");

const Cred = struct { url: []const u8, token: []const u8 };

fn cred(io: Io, alloc: std.mem.Allocator, home: []const u8) ?Cred {
    const c = context.cred(io, alloc, home) orelse return null;
    return .{ .url = c.url, .token = c.token };
}

fn notLoggedIn() u8 {
    log.err("not logged in \u{2014} run `work login <url> --email \u{2026} --password \u{2026}`");
    return 1;
}

fn httpErr(alloc: std.mem.Allocator, status: u16, body: []const u8) u8 {
    const msg = cloud.jsonField(body, "error") orelse "request failed";
    log.err(std.fmt.allocPrint(alloc, "{s} (HTTP {d})", .{ msg, status }) catch "request failed");
    return 1;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// value following a `--name` flag, or null.
fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (eql(args[i], name)) return args[i + 1];
    }
    return null;
}

// first non-`--flag` argument (the positional id for read/reply).
fn positional(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--")) {
            i += 1; // skip the flag's value
        } else {
            return args[i];
        }
    }
    return null;
}

// Percent-encode a value for a query string (message-ids carry <, >, @).
fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            try out.append(alloc, ch);
        } else {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "%{X:0>2}", .{ch}));
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn email(io: Io, alloc: std.mem.Allocator, sub: []const u8, args: []const []const u8, home: []const u8) !u8 {
    if (eql(sub, "send")) return send(io, alloc, args, home);
    if (eql(sub, "inbox") or eql(sub, "list") or eql(sub, "")) return inbox(io, alloc, args, home);
    if (eql(sub, "read")) return read(io, alloc, args, home);
    if (eql(sub, "reply")) return reply(io, alloc, args, home);
    log.err("usage: work email send|inbox|read|reply  \u{00b7}  send --to \u{2026} --subject \u{2026} --body \u{2026}");
    return 1;
}

fn send(io: Io, alloc: std.mem.Allocator, args: []const []const u8, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    const to = flag(args, "--to") orelse {
        log.err("usage: work email send --to <addr> --subject <s> --body <text>");
        return 1;
    };
    const subject = flag(args, "--subject") orelse "";
    const text = flag(args, "--body") orelse flag(args, "--text") orelse "";

    const payload = try std.fmt.allocPrint(alloc, "{{\"to\":\"{s}\",\"subject\":\"{s}\",\"text\":\"{s}\"}}", .{
        try cloud.jsonEscape(alloc, to), try cloud.jsonEscape(alloc, subject), try cloud.jsonEscape(alloc, text),
    });
    log.prompt(try std.fmt.allocPrint(alloc, "work email send --to {s}", .{to}));
    const url = try std.fmt.allocPrint(alloc, "{s}/api/email/send", .{c.url});
    const res = cloud.request(io, alloc, .POST, url, c.token, payload) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status < 200 or res.status >= 300) return httpErr(alloc, res.status, res.body);
    log.ok(try std.fmt.allocPrint(alloc, "sent to {s}", .{to}));
    return 0;
}

fn inbox(io: Io, alloc: std.mem.Allocator, args: []const []const u8, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    const status = flag(args, "--status");
    const url = if (status) |s|
        try std.fmt.allocPrint(alloc, "{s}/api/email/inbox?status={s}", .{ c.url, s })
    else
        try std.fmt.allocPrint(alloc, "{s}/api/email/inbox", .{c.url});
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);
    log.out(res.body);
    log.out("\n");
    return 0;
}

fn read(io: Io, alloc: std.mem.Allocator, args: []const []const u8, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    const id = positional(args) orelse flag(args, "--id") orelse {
        log.err("usage: work email read <id>");
        return 1;
    };
    const url = try std.fmt.allocPrint(alloc, "{s}/api/email/message?id={s}", .{ c.url, try urlEncode(alloc, id) });
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);
    log.out(res.body);
    log.out("\n");
    return 0;
}

fn reply(io: Io, alloc: std.mem.Allocator, args: []const []const u8, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    const id = positional(args) orelse flag(args, "--id") orelse {
        log.err("usage: work email reply <id> --body <text>");
        return 1;
    };
    const text = flag(args, "--body") orelse flag(args, "--text") orelse "";
    const payload = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"text\":\"{s}\"}}", .{
        try cloud.jsonEscape(alloc, id), try cloud.jsonEscape(alloc, text),
    });
    log.prompt(try std.fmt.allocPrint(alloc, "work email reply {s}", .{id}));
    const url = try std.fmt.allocPrint(alloc, "{s}/api/email/reply", .{c.url});
    const res = cloud.request(io, alloc, .POST, url, c.token, payload) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status < 200 or res.status >= 300) return httpErr(alloc, res.status, res.body);
    log.ok("replied");
    return 0;
}
