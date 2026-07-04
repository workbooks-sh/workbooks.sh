//! `work cloud …` — drive the active nexus's cloud provisioning from the CLI, using the same
//! `/api/cloud/*` endpoints the dashboard uses and the stored personal-access token (`work login`).
//! `provision` stands up (or rolls) this org's autopoet machine, `machine` inspects it, `down` tears
//! it down. The nexus is the login target — switch which one with `work login <url>` / `work use`.
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

/// `work cloud provision` — stand up (or roll) this org's autopoet machine.
pub fn provision(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    log.prompt("work cloud provision");
    const url = try std.fmt.allocPrint(alloc, "{s}/api/cloud/provision", .{c.url});
    // Zig's http client asserts a POST carries a body — send an empty JSON object (the endpoint reads none).
    const res = cloud.request(io, alloc, .POST, url, c.token, "{}") catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status < 200 or res.status >= 300) return httpErr(alloc, res.status, res.body);
    const img = cloud.jsonField(res.body, "image") orelse "?";
    const region = cloud.jsonField(res.body, "region") orelse "?";
    const machine_id = cloud.jsonField(res.body, "fly_machine") orelse "?";
    const st = cloud.jsonField(res.body, "state") orelse "?";
    log.step(try std.fmt.allocPrint(alloc, "machine {s} \u{00b7} {s} \u{00b7} {s} \u{00b7} {s}", .{ machine_id, img, region, st }));
    return 0;
}

/// `work cloud machine` — inspect this org's machine (state + image).
pub fn machine(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    log.prompt("work cloud machine");
    const url = try std.fmt.allocPrint(alloc, "{s}/api/cloud/machine", .{c.url});
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status == 404) {
        log.step("no machine yet \u{2014} run `work cloud provision`");
        return 0;
    }
    if (res.status != 200) return httpErr(alloc, res.status, res.body);
    const st = cloud.jsonField(res.body, "state") orelse "?";
    const img = cloud.jsonField(res.body, "image") orelse "?";
    log.step(try std.fmt.allocPrint(alloc, "state {s} \u{00b7} {s}", .{ st, img }));
    return 0;
}

/// `work cloud down` — tear down this org's machine (storage-only until re-provisioned).
pub fn down(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    log.prompt("work cloud down");
    const url = try std.fmt.allocPrint(alloc, "{s}/api/cloud/machine", .{c.url});
    const res = cloud.request(io, alloc, .DELETE, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status < 200 or res.status >= 300) return httpErr(alloc, res.status, res.body);
    log.step("machine torn down");
    return 0;
}
