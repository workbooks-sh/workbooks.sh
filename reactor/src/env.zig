//! `work env …` — manage the NEXUS's env/secret store from the CLI, the same one editable secret list
//! the dashboard shows (POST/GET/DELETE /api/platform/env, scope "nexus"). Authenticated with the
//! stored personal-access token (`work login`); the runtime reads these via Nexus.Secrets (store-first).
//! Distinct from `work secret`, which is the LOCAL macOS Keychain. `ls` lists names (values never leave
//! the server unless revealed), `set NAME [VALUE]` adds/replaces (value via arg or WORK_ENV_VALUE),
//! `rm NAME` deletes.
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

pub fn env(io: Io, alloc: std.mem.Allocator, home: []const u8, sub: []const u8, name: []const u8, value: []const u8) !u8 {
    if (std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "list") or sub.len == 0) return ls(io, alloc, home);
    if (std.mem.eql(u8, sub, "set")) return set(io, alloc, home, name, value);
    if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "delete")) return rm(io, alloc, home, name);
    log.err("usage: work env ls  \u{b7}  work env set NAME [VALUE]  \u{b7}  work env rm NAME");
    return 1;
}

/// `work env ls` — the nexus env store (names + sizes; values stay server-side).
fn ls(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    log.prompt("work env ls");
    const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/env?scope=nexus", .{c.url});
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);

    const names = try cloud.jsonStringsAll(alloc, res.body, "name");
    if (names.len == 0) {
        log.step("no secrets in the nexus store yet \u{2014} `work env set NAME VALUE`");
        return 0;
    }
    for (names) |n| log.print("  {s}{s}{s}\n", .{ log.cmd_c, n, log.reset });
    return 0;
}

/// `work env set NAME [VALUE]` — add or replace a nexus-scoped secret. Value from VALUE or WORK_ENV_VALUE.
fn set(io: Io, alloc: std.mem.Allocator, home: []const u8, name: []const u8, value: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    if (name.len == 0 or value.len == 0) {
        log.err("usage: work env set NAME VALUE   (or set WORK_ENV_VALUE for the value)");
        return 1;
    }
    log.prompt(try std.fmt.allocPrint(alloc, "work env set {s}", .{name}));

    // Replace if it already exists (PATCH by id), else create — so `set` is idempotent like an env var.
    const existing = try findId(io, alloc, c, name);
    const payload = try std.fmt.allocPrint(
        alloc,
        "{{\"name\":\"{s}\",\"value\":\"{s}\",\"scope\":\"nexus\"}}",
        .{ try cloud.jsonEscape(alloc, name), try cloud.jsonEscape(alloc, value) },
    );

    const res = if (existing) |id| blk: {
        const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/env/{s}", .{ c.url, id });
        break :blk cloud.request(io, alloc, .PATCH, url, c.token, payload) catch |e| {
            log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
            return 1;
        };
    } else blk: {
        const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/env", .{c.url});
        break :blk cloud.request(io, alloc, .POST, url, c.token, payload) catch |e| {
            log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
            return 1;
        };
    };

    if (res.status != 200 and res.status != 201) return httpErr(alloc, res.status, res.body);
    log.ok(try std.fmt.allocPrint(alloc, "{s} {s}", .{ if (existing != null) "replaced" else "set", name }));
    return 0;
}

/// `work env rm NAME` — delete a nexus-scoped secret by name.
fn rm(io: Io, alloc: std.mem.Allocator, home: []const u8, name: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    if (name.len == 0) {
        log.err("usage: work env rm NAME");
        return 1;
    }
    log.prompt(try std.fmt.allocPrint(alloc, "work env rm {s}", .{name}));
    const id = (try findId(io, alloc, c, name)) orelse {
        log.err(try std.fmt.allocPrint(alloc, "no secret named {s}", .{name}));
        return 1;
    };
    const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/env/{s}", .{ c.url, id });
    const res = cloud.request(io, alloc, .DELETE, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);
    log.ok(try std.fmt.allocPrint(alloc, "removed {s}", .{name}));
    return 0;
}

// The store id for a nexus-scoped secret by name, or null. Aligns parallel name/id/scope arrays.
fn findId(io: Io, alloc: std.mem.Allocator, c: Cred, name: []const u8) !?[]const u8 {
    const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/env?scope=nexus", .{c.url});
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch return null;
    if (res.status != 200) return null;
    const names = try cloud.jsonStringsAll(alloc, res.body, "name");
    const ids = try cloud.jsonStringsAll(alloc, res.body, "id");
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name) and i < ids.len) return ids[i];
    }
    return null;
}
