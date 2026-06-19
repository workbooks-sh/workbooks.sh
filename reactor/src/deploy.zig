//! deploy — stand up a runtime for a workbook, local or cloud. The config is a
//! `deploy do … end` declaration in a `.work` file (`deployment.work`) — config
//! lives with the workbook, on-canon (HTML is only ever a build output, never a
//! config surface). `init` scaffolds it; `validate` runs the coherence rules;
//! apply/status/verify/down route by engine-place to a backend. Config parse +
//! validation are pure (testable); secrets never live in the file — they come from ENV.
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
    const provider_block = if (cloud)
        "\n  provider=\"fly\"\n  app=\"my-workbook\"\n  region=\"iad\""
    else
        "";
    // The compiled-component cache. Local: a dir on the PERSISTENT data volume (the libkrun VM / Fly
    // machine wipes the rootfs on restart — /data survives). Cloud: an egress-free S3-compatible store
    // (R2/MinIO/B2) so "compile once" is durable + fleet-wide across scale-to-zero machines.
    const cache_block = if (cloud)
        "\n  component-cache=\"r2://my-workbook-cache/components\"\n  component-cache-endpoint=\"https://ACCOUNT_ID.r2.cloudflarestorage.com\"\n  component-cache-region=\"auto\""
    else
        "\n  component-cache=\"/data/build/components\"";
    return std.fmt.allocPrint(alloc,
        \\# Deployment
        \\
        \\How this workbook is deployed. These settings live with the workbook —
        \\version-controlled, not JSON and not env vars. The ONLY things from your
        \\deploy ENV are SECRETS + per-machine identity:
        \\  WB_DATABASE_URL (postgres) · WB_S3_ACCESS_KEY_ID / WB_S3_SECRET_ACCESS_KEY (cache store)
        \\Compile-lane knobs (optional; defaults shown): compile-concurrency=cores ·
        \\compile-cache="on" · compile-cache-version="wbc1" · pm-debug="off"
        \\
        \\deploy do
        \\  engine-place="{s}"
        \\  tenancy-mode="single"
        \\  storage="{s}"
        \\  database="{s}"
        \\  auth="trusted"{s}{s}
        \\end
        \\
    , .{
        place,
        if (cloud) "s3" else "local-fs",
        if (cloud) "postgres" else "sqlite",
        provider_block,
        cache_block,
    });
}

/// Read a `name="value"` setting from the `deploy do … end` block of a `.work` source.
pub fn attr(src: []const u8, name: []const u8, default: []const u8) []const u8 {
    const blk = std.mem.indexOf(u8, src, "deploy do") orelse return default;
    const end = std.mem.indexOfPos(u8, src, blk, "\nend") orelse src.len;
    const region = src[blk..@min(end, src.len)];
    var pat: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "{s}=\"", .{name}) catch return default;
    const at = std.mem.indexOf(u8, region, p) orelse return default;
    const vs = at + p.len;
    const ve = std.mem.indexOfScalarPos(u8, region, vs, '"') orelse return default;
    return region[vs..ve];
}

/// Validate a parsed config → list of issue strings ([] means coherent).
pub fn validate(alloc: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var issues: std.ArrayList([]const u8) = .empty;
    const place = attr(src, "engine-place", "local");
    const tenancy = attr(src, "tenancy-mode", "single");
    const storage = attr(src, "storage", "local-fs");
    const database = attr(src, "database", "sqlite");
    const auth = attr(src, "auth", "trusted");

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
    if (eql(storage, "s3") and (attr(src, "storage-bucket", "").len == 0 or attr(src, "storage-endpoint", "").len == 0))
        try issues.append(alloc, "storage: s3 needs storage-bucket + storage-endpoint");
    if (eql(database, "postgres"))
        try issues.append(alloc, "database: postgres needs WB_DATABASE_URL in your deploy ENV");

    // The compiled-component cache: a remote (r2://|s3://) store needs an endpoint in the file + S3
    // creds in ENV; a local value must be an ABSOLUTE path (it lives inside the VM/machine, and a
    // relative one would land on the ephemeral rootfs instead of the persistent volume).
    const cache = attr(src, "component-cache", "");
    const remote_cache = std.mem.startsWith(u8, cache, "r2://") or std.mem.startsWith(u8, cache, "s3://");
    if (remote_cache and attr(src, "component-cache-endpoint", "").len == 0)
        try issues.append(alloc, "component-cache: r2://|s3:// needs component-cache-endpoint (+ WB_S3_ACCESS_KEY_ID / WB_S3_SECRET_ACCESS_KEY in your deploy ENV)");
    if (cache.len != 0 and !remote_cache and cache[0] != '/')
        try issues.append(alloc, "component-cache: a local path must be absolute (e.g. /data/build/components) so it sits on the persistent volume, not the ephemeral rootfs");

    return issues.toOwnedSlice(alloc);
}

// ── verbs ───────────────────────────────────────────────────────────────────────────────────
pub fn init(io: Io, alloc: std.mem.Allocator, place_in: []const u8, dir: []const u8, force: bool) !u8 {
    const place = if (isPlace(place_in)) place_in else "local";
    const path = try std.fs.path.join(alloc, &.{ dir, "deployment.work" });
    log.prompt(try std.fmt.allocPrint(alloc, "work deploy init {s} {s}", .{ place, dir }));

    if (!force) {
        if (fs.readFile(io, alloc, path)) |_| {
            log.warn("deployment.work already exists — pass --force to overwrite");
            return 1;
        } else |_| {}
    }
    try fs.writeFile(io, path, try scaffold(alloc, place));
    log.ok(try std.fmt.allocPrint(alloc, "wrote deployment.work \u{b7} engine-place={s}", .{place}));
    log.step("edit it, then `work deploy validate` \u{2192} `work deploy apply`");
    return 0;
}

pub fn validateVerb(io: Io, alloc: std.mem.Allocator, file: []const u8) !u8 {
    log.prompt(try std.fmt.allocPrint(alloc, "work deploy validate {s}", .{file}));
    const src = fs.readFile(io, alloc, file) catch {
        log.err("no deployment.work — run `work deploy init` first");
        return 1;
    };
    if (std.mem.indexOf(u8, src, "deploy do") == null) {
        log.err("no `deploy do … end` block in the config");
        return 1;
    }
    const issues = try validate(alloc, src);
    if (issues.len == 0) {
        log.ok(try std.fmt.allocPrint(alloc, "config is coherent \u{b7} engine-place={s}", .{attr(src, "engine-place", "local")}));
        return 0;
    }
    log.err(try std.fmt.allocPrint(alloc, "{d} issue(s)", .{issues.len}));
    for (issues) |i| log.step(i);
    return 1;
}

pub fn apply(io: Io, alloc: std.mem.Allocator, file: []const u8) !u8 {
    log.prompt(try std.fmt.allocPrint(alloc, "work deploy apply {s}", .{file}));
    const src = fs.readFile(io, alloc, file) catch {
        log.err("no deployment.work — run `work deploy init` first");
        return 1;
    };
    const issues = try validate(alloc, src);
    if (issues.len > 0) {
        log.err("config invalid — fix it first (`work deploy validate`)");
        for (issues) |i| log.step(i);
        return 1;
    }
    const place = attr(src, "engine-place", "local");
    if (eql(place, "local")) {
        log.ok("local target — runs the one OCI image in a krunvm/container");
        log.step("image build + boot lands with the nexus image recipe");
    } else {
        log.ok(try std.fmt.allocPrint(alloc, "cloud target: {s} \u{b7} {s}", .{ attr(src, "provider", "fly"), attr(src, "app", "(no app)") }));
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

    const bad = "deploy do\n engine-place=\"cloud\" tenancy-mode=\"multi\" storage=\"s3\" database=\"postgres\" auth=\"trusted\"\nend";
    const issues = try validate(a, bad);
    try std.testing.expect(issues.len >= 3);

    // cloud scaffold carries an r2:// cache WITH an endpoint → no cache issue raised for it.
    const cl = try scaffold(a, "cloud");
    for (try validate(a, cl)) |i| try std.testing.expect(std.mem.indexOf(u8, i, "component-cache:") == null);
}

test "validate flags a remote cache with no endpoint + a relative local cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const no_ep = "deploy do\n engine-place=\"cloud\" component-cache=\"r2://bkt/components\"\nend";
    try std.testing.expect((try validate(a, no_ep)).len >= 1);

    const rel = "deploy do\n engine-place=\"local\" component-cache=\"build/components\"\nend";
    try std.testing.expect((try validate(a, rel)).len >= 1);
}
