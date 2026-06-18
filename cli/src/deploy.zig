//! deploy — stand up a runtime for a workbook, local or cloud. The config is a single `<work-deploy>`
//! HTML element (no JSON, on-canon). `init` scaffolds it; `validate` runs the coherence rules (the
//! same lockouts the Elixir kit had); apply/status/verify/down route by engine-place to a backend.
//! Config parse + validation are pure (testable); secrets never live in the file — they come from ENV.
const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const log = @import("log.zig");

const places = [_][]const u8{ "local", "cloud" };
const tenancies = [_][]const u8{ "single", "multi" };
const storages = [_][]const u8{ "local-fs", "s3" };
const databases = [_][]const u8{ "sqlite", "postgres" };
const auths = [_][]const u8{ "trusted", "betterauth", "clerk", "oidc" };

pub fn scaffold(alloc: std.mem.Allocator, place: []const u8) ![]const u8 {
    const cloud = std.mem.eql(u8, place, "cloud");
    return std.fmt.allocPrint(alloc,
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8"><title>Deployment</title></head><body>
        \\<!-- secrets (WB_DATABASE_URL / WB_S3_*) come from your deploy ENV, never this file -->
        \\<work-deploy
        \\  engine-place="{s}"
        \\  tenancy-mode="single"
        \\  storage="{s}"
        \\  database="{s}"
        \\  auth="trusted"{s}>
        \\</work-deploy>
        \\</body></html>
        \\
    , .{
        place,
        if (cloud) "s3" else "local-fs",
        if (cloud) "postgres" else "sqlite",
        if (cloud) "\n  provider=\"fly\"\n  app=\"my-workbook\"\n  region=\"iad\"" else "",
    });
}

pub fn attr(html: []const u8, name: []const u8, default: []const u8) []const u8 {
    const wd = std.mem.indexOf(u8, html, "<work-deploy") orelse return default;
    const end = std.mem.indexOfScalarPos(u8, html, wd, '>') orelse html.len;
    const region = html[wd..@min(end, html.len)];
    var pat: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "{s}=\"", .{name}) catch return default;
    const at = std.mem.indexOf(u8, region, p) orelse return default;
    const vs = at + p.len;
    const ve = std.mem.indexOfScalarPos(u8, region, vs, '"') orelse return default;
    return region[vs..ve];
}

/// Validate a parsed config → list of issue strings ([] means coherent).
pub fn validate(alloc: std.mem.Allocator, html: []const u8) ![]const []const u8 {
    var issues: std.ArrayList([]const u8) = .empty;
    const place = attr(html, "engine-place", "local");
    const tenancy = attr(html, "tenancy-mode", "single");
    const storage = attr(html, "storage", "local-fs");
    const database = attr(html, "database", "sqlite");
    const auth = attr(html, "auth", "trusted");

    try enumCheck(alloc, &issues, "engine-place", place, &places);
    try enumCheck(alloc, &issues, "tenancy-mode", tenancy, &tenancies);
    try enumCheck(alloc, &issues, "storage", storage, &storages);
    try enumCheck(alloc, &issues, "database", database, &databases);
    try enumCheck(alloc, &issues, "auth", auth, &auths);

    if (eql(tenancy, "multi") and eql(database, "sqlite"))
        try issues.append(alloc, "tenancy-mode: multi needs database: postgres (sqlite can't isolate tenants)");
    if (eql(tenancy, "multi") and eql(auth, "trusted"))
        try issues.append(alloc, "tenancy-mode: multi needs real auth (betterauth|clerk|oidc) — trusted has no identity");
    if (eql(place, "cloud") and eql(auth, "trusted"))
        try issues.append(alloc, "engine-place: cloud + auth: trusted is an OPEN control plane — set WB_PUBLIC_BEARER in your deploy ENV, or use real auth");
    if (eql(storage, "s3") and (attr(html, "storage-bucket", "").len == 0 or attr(html, "storage-endpoint", "").len == 0))
        try issues.append(alloc, "storage: s3 needs storage-bucket + storage-endpoint");
    if (eql(database, "postgres"))
        try issues.append(alloc, "database: postgres needs WB_DATABASE_URL in your deploy ENV");

    return issues.toOwnedSlice(alloc);
}

// ── verbs ───────────────────────────────────────────────────────────────────────────────────
pub fn init(io: Io, alloc: std.mem.Allocator, place_in: []const u8, dir: []const u8, force: bool) !u8 {
    const place = if (isPlace(place_in)) place_in else "local";
    const path = try std.fs.path.join(alloc, &.{ dir, "deployment.html" });
    log.prompt(try std.fmt.allocPrint(alloc, "work deploy init {s} {s}", .{ place, dir }));

    if (!force) {
        if (fs.readFile(io, alloc, path)) |_| {
            log.warn("deployment.html already exists — pass --force to overwrite");
            return 1;
        } else |_| {}
    }
    try fs.writeFile(io, path, try scaffold(alloc, place));
    log.ok(try std.fmt.allocPrint(alloc, "wrote deployment.html \u{b7} engine-place={s}", .{place}));
    log.step("edit it, then `work deploy validate` \u{2192} `work deploy apply`");
    return 0;
}

pub fn validateVerb(io: Io, alloc: std.mem.Allocator, file: []const u8) !u8 {
    log.prompt(try std.fmt.allocPrint(alloc, "work deploy validate {s}", .{file}));
    const html = fs.readFile(io, alloc, file) catch {
        log.err("no deployment.html — run `work deploy init` first");
        return 1;
    };
    if (std.mem.indexOf(u8, html, "<work-deploy") == null) {
        log.err("no <work-deploy> element in the config");
        return 1;
    }
    const issues = try validate(alloc, html);
    if (issues.len == 0) {
        log.ok(try std.fmt.allocPrint(alloc, "config is coherent \u{b7} engine-place={s}", .{attr(html, "engine-place", "local")}));
        return 0;
    }
    log.err(try std.fmt.allocPrint(alloc, "{d} issue(s)", .{issues.len}));
    for (issues) |i| log.step(i);
    return 1;
}

pub fn apply(io: Io, alloc: std.mem.Allocator, file: []const u8) !u8 {
    log.prompt(try std.fmt.allocPrint(alloc, "work deploy apply {s}", .{file}));
    const html = fs.readFile(io, alloc, file) catch {
        log.err("no deployment.html — run `work deploy init` first");
        return 1;
    };
    const issues = try validate(alloc, html);
    if (issues.len > 0) {
        log.err("config invalid — fix it first (`work deploy validate`)");
        for (issues) |i| log.step(i);
        return 1;
    }
    const place = attr(html, "engine-place", "local");
    if (eql(place, "local")) {
        log.ok("local target — runs the one OCI image in a krunvm/container");
        log.step("image build + boot lands with the nexus image recipe");
    } else {
        log.ok(try std.fmt.allocPrint(alloc, "cloud target: {s} \u{b7} {s}", .{ attr(html, "provider", "fly"), attr(html, "app", "(no app)") }));
        log.step("cloud apply provisions via the control plane (`work login`)");
    }
    return 0;
}

fn enumCheck(alloc: std.mem.Allocator, issues: *std.ArrayList([]const u8), key: []const u8, value: []const u8, allowed: []const []const u8) !void {
    for (allowed) |a| if (eql(a, value)) return;
    try issues.append(alloc, try std.fmt.allocPrint(alloc, "{s}: \"{s}\" is not valid", .{ key, value }));
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn isPlace(p: []const u8) bool {
    for (places) |x| if (eql(x, p)) return true;
    return false;
}

test "scaffold → validate: coherent local, flagged cloud+multi+trusted+s3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const local = try scaffold(a, "local");
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, local)).len);

    const bad = "<work-deploy engine-place=\"cloud\" tenancy-mode=\"multi\" storage=\"s3\" database=\"postgres\" auth=\"trusted\">";
    const issues = try validate(a, bad);
    try std.testing.expect(issues.len >= 3);
}
