//! `work agent …` — drive the nexus's agents from the CLI, exactly as the dashboard does, using the
//! stored personal-access token (`work login`). `ls` lists the agent roster (GET /cloud/agents), `run`
//! executes one on a brief (POST /cloud/agent/run) and prints the answer, and `work runs` shows the
//! durable run ledger (GET /cloud/runs) — the same runs that appear in the dashboard's Runs view.
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

/// `work agent ls` — the agent roster on the active nexus.
pub fn list(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    log.prompt("work agent ls");
    const url = try std.fmt.allocPrint(alloc, "{s}/cloud/agents", .{c.url});
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);

    const names = try cloud.jsonStringsAll(alloc, res.body, "name");
    const labels = try cloud.jsonStringsAll(alloc, res.body, "label");
    if (names.len == 0) {
        log.step("no agents on this nexus");
        return 0;
    }
    for (names, 0..) |n, i| {
        const lbl = if (i < labels.len) labels[i] else "";
        log.print("  {s}{s: <14}{s}{s}{s}{s}\n", .{ log.cmd_c, n, log.reset, log.dim_c, lbl, log.reset });
    }
    return 0;
}

/// `work agent run <name> "<task>" [--workspace <ws>]` — run an agent on a brief, print the answer.
pub fn run(io: Io, alloc: std.mem.Allocator, home: []const u8, name: []const u8, task: []const u8, workspace: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    if (name.len == 0 or task.len == 0) {
        log.err("usage: work agent run <name> \"<task>\" [--workspace <ws>]");
        return 1;
    }
    log.prompt(try std.fmt.allocPrint(alloc, "work agent run {s}", .{name}));

    const ws_field = if (workspace.len > 0)
        try std.fmt.allocPrint(alloc, ",\"workspace\":\"{s}\"", .{try cloud.jsonEscape(alloc, workspace)})
    else
        "";
    const payload = try std.fmt.allocPrint(
        alloc,
        "{{\"agent\":\"{s}\",\"task\":\"{s}\",\"u\":\"work-cli\"{s}}}",
        .{ try cloud.jsonEscape(alloc, name), try cloud.jsonEscape(alloc, task), ws_field },
    );

    const url = try std.fmt.allocPrint(alloc, "{s}/cloud/agent/run", .{c.url});
    // Agent runs can take a while; the underlying client carries its own timeout.
    const res = cloud.request(io, alloc, .POST, url, c.token, payload) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);

    const rid = cloud.jsonField(res.body, "run") orelse "?";
    const status = cloud.jsonField(res.body, "status") orelse "?";
    const turns = cloud.jsonField(res.body, "turns") orelse "";
    _ = turns;
    log.ok(try std.fmt.allocPrint(alloc, "run {s} \u{b7} {s}", .{ rid, status }));
    const answer = cloud.jsonString(alloc, res.body, "answer") orelse "";
    if (answer.len > 0) {
        log.out("\n");
        log.out(answer);
        log.out("\n");
    }
    return 0;
}

/// `work runs` — the durable run ledger on the active nexus (the dashboard's Runs view, headless).
pub fn runs(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    const c = cred(io, alloc, home) orelse return notLoggedIn();
    log.prompt("work runs");
    const url = try std.fmt.allocPrint(alloc, "{s}/cloud/runs", .{c.url});
    const res = cloud.request(io, alloc, .GET, url, c.token, null) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "nexus unreachable ({s})", .{@errorName(e)}));
        return 1;
    };
    if (res.status != 200) return httpErr(alloc, res.status, res.body);

    const agents = try cloud.jsonStringsAll(alloc, res.body, "agent");
    const statuses = try cloud.jsonStringsAll(alloc, res.body, "status");
    const tasks = try cloud.jsonStringsAll(alloc, res.body, "task");
    if (agents.len == 0) {
        log.step("no runs yet \u{2014} `work agent run <name> \"<task>\"`");
        return 0;
    }
    for (agents, 0..) |ag, i| {
        const st = if (i < statuses.len) statuses[i] else "?";
        const tk = if (i < tasks.len) tasks[i] else "";
        const tk_short = if (tk.len > 56) tk[0..56] else tk;
        log.print("  {s}{s: <12}{s}{s: <9}{s}{s}{s}\n", .{ log.cmd_c, ag, log.reset, st, log.dim_c, tk_short, log.reset });
    }
    return 0;
}
