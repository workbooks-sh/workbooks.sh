//! deploy — stand up a runtime for a workbook, local or cloud. The config is a
//! `deploy do … end` declaration in a `.work` file (`deployment.work`) — config
//! lives with the workbook, on-canon (HTML is only ever a build output, never a
//! config surface). `init` scaffolds it; `validate` runs the coherence rules;
//! apply/status/verify/down route by engine-place to a backend. Config parse +
//! validation are pure (testable); secrets never live in the file — they come from ENV.
const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const context = @import("context.zig");
const cloudapi = @import("cloud.zig");
const log = @import("log.zig");

// engine-place targets: `local` (vfkit microVM), `cloud` (Fly), and `desktop` (Worktop — a
// self-contained Burrito-wrapped binary that boots a Nexus headless on the host, no VM/container).
// desktop is a DEPLOY TARGET orthogonal to the front-end: it changes WHERE a Nexus runs, not what it
// serves. It's inherently TRUSTED + single-user/local (native units can't be sandboxed in-process —
// "the trust boundary is the machine"); untrusted third-party Nexuses still use the vfkit microVM.
const places = [_][]const u8{ "local", "cloud", "desktop" };
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
    return blockAttr(src, "deploy do", name, default);
}

/// Read `name="value"` from a named `<block> … end` region of a `.work` source.
pub fn blockAttr(src: []const u8, block: []const u8, name: []const u8, default: []const u8) []const u8 {
    const blk = std.mem.indexOf(u8, src, block) orelse return default;
    const end = std.mem.indexOfPos(u8, src, blk, "\nend") orelse src.len;
    const region = src[blk..@min(end, src.len)];
    var pat: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "{s}=\"", .{name}) catch return default;
    const at = std.mem.indexOf(u8, region, p) orelse return default;
    const vs = at + p.len;
    const ve = std.mem.indexOfScalarPos(u8, region, vs, '"') orelse return default;
    return region[vs..ve];
}

// The provisioned-target record. State lives in `.work/runtime.state` as a `.work` block (blocks
// are the source of truth — NOT JSON), so verify/status/down can find what `apply` stood up.
const STATE_PATH = ".work/runtime.state";

fn writeState(io: Io, alloc: std.mem.Allocator, target: []const u8, id: []const u8, url: []const u8, machine: []const u8) !void {
    Io.Dir.cwd().createDirPath(io, ".work") catch {};
    const body = try std.fmt.allocPrint(alloc,
        \\# Provisioned runtime (written by `work deploy apply`)
        \\
        \\runtime do
        \\  target="{s}"
        \\  id="{s}"
        \\  url="{s}"
        \\  machine="{s}"
        \\end
        \\
    , .{ target, id, url, machine });
    try fs.writeFile(io, STATE_PATH, body);
}

fn readState(io: Io, alloc: std.mem.Allocator) ?[]const u8 {
    return fs.readFile(io, alloc, STATE_PATH) catch null;
}

/// `work deploy down` — tear down what `apply` stood up (cloud: DELETE the nexus via the control
/// plane; local: stop+remove the krunvm microVM via the deploy bridge), then clear the state.
pub fn down(io: Io, alloc: std.mem.Allocator, home: []const u8) !u8 {
    log.prompt("work deploy down");
    const state = readState(io, alloc) orelse {
        log.err("nothing to tear down — no .work/runtime.state (run `work deploy apply` first)");
        return 1;
    };
    const target = blockAttr(state, "runtime do", "target", "");

    if (eql(target, "cloud")) {
        const c = context.cred(io, alloc, home) orelse {
            log.err("cloud teardown needs a control-plane login — run `work login`");
            return 1;
        };
        const id = blockAttr(state, "runtime do", "id", "");
        const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/nexuses/{s}", .{ c.url, id });
        const res = cloudapi.request(io, alloc, .DELETE, url, c.token, null) catch |e| {
            log.err(try std.fmt.allocPrint(alloc, "control plane unreachable ({s})", .{@errorName(e)}));
            return 1;
        };
        if (res.status != 200 and res.status != 204) {
            log.err(try std.fmt.allocPrint(alloc, "teardown failed (HTTP {d}): {s}", .{ res.status, res.body }));
            return 1;
        }
        log.ok(try std.fmt.allocPrint(alloc, "nexus {s} torn down", .{id}));
    } else if (eql(target, "desktop")) {
        // Worktop is just a host binary — there's no provisioned VM/machine to delete. Stop the
        // process you launched (Ctrl-C / kill); `rm -rf burrito_out` drops the build output.
        log.ok("desktop (Worktop) is a local binary — stop the process you launched (Ctrl-C / kill); nothing provisioned to tear down");
    } else {
        const r = std.process.run(alloc, io, .{ .argv = &.{ "mix", "nexus.deploy.down" } }) catch |e| {
            log.err(try std.fmt.allocPrint(alloc, "could not invoke the deploy bridge ({s})", .{@errorName(e)}));
            return 1;
        };
        if (!(r.term == .exited and r.term.exited == 0)) {
            log.err(try std.fmt.allocPrint(alloc, "local teardown failed:\n{s}{s}", .{ r.stdout, r.stderr }));
            return 1;
        }
        log.ok("local nexus stopped + removed");
    }

    fs.writeFile(io, STATE_PATH, "# torn down\n") catch {};
    return 0;
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
    // Worktop (desktop) runs the whole Nexus — including native server/worker/def/hook/auth units —
    // in one trusted host process; it can't isolate tenants (the trust boundary is the machine), so
    // it's single-user by construction. Multi-tenant workloads belong on cloud (or a per-tenant vfkit).
    if (eql(place, "desktop") and eql(tenancy, "multi"))
        try issues.append(alloc, "engine-place: desktop is single-user (the trust boundary is the machine) — tenancy-mode must be single; use cloud for multi-tenant");
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

/// `work deploy <dir> [--nexus <name>]` — mount a workbook into a running nexus. The target is a
/// nexus BY NAME (a context target), resolved to its URL; default = the active context (local). One
/// nexus hosts many workbooks, each at /<name> — like one host serving many sites.
pub fn deployWorkbook(io: Io, alloc: std.mem.Allocator, home: []const u8, cwd: []const u8, dir: []const u8, nexus_name: []const u8) !u8 {
    // `--nexus local` targets the running vfkit nexus at the guest URL `apply` recorded in
    // .work/runtime.state (its NAT IP, not localhost) — so the edit→push→serve dev loop works locally.
    const base = if (std.mem.eql(u8, nexus_name, "local"))
        (if (readState(io, alloc)) |s| blockAttr(s, "runtime do", "url", "") else "")
    else if (nexus_name.len > 0)
        try context.nexusByName(io, alloc, home, nexus_name)
    else
        try context.nexusUrl(io, alloc, home);

    if (base.len == 0) {
        log.err("no local nexus running — `work deploy apply` (local) first, or pass a --nexus <name>");
        return 1;
    }

    // Absolute path (the nexus mounts from it, same machine). Resolve against $PWD if relative.
    const abs = if (std.fs.path.isAbsolute(dir)) try alloc.dupe(u8, dir) else try std.fs.path.resolve(alloc, &.{ cwd, dir });

    const empty: []const []const u8 = &.{};
    if ((fs.workFiles(io, alloc, abs) catch empty).len == 0) {
        log.err(try std.fmt.allocPrint(alloc, "no workbook (.work files) at {s}", .{abs}));
        return 1;
    }

    const name = std.fs.path.basename(abs);

    log.prompt(try std.fmt.allocPrint(alloc, "work deploy {s} \u{2192} {s}", .{ name, base }));

    // The nexus IS a git remote: push the workbook's files to `<base>/git/<name>.git`. A post-receive
    // checks them out into the workspace dir on the nexus (works for a REMOTE nexus, not just same-box).
    // We use a reused local mirror git-dir (~/.work/repos/<name>.git) over the source work-tree, so the
    // source dir is never touched and pushes are incremental.
    const token = if (context.cred(io, alloc, home)) |c| c.token else "";

    // Authed remote URL: scheme://x:<token>@host/git/<name>.git
    const remote = blk: {
        const sep = std.mem.indexOf(u8, base, "://") orelse break :blk try std.fmt.allocPrint(alloc, "{s}/git/{s}.git", .{ base, name });
        const scheme = base[0 .. sep + 3];
        const hostpart = base[sep + 3 ..];
        break :blk if (token.len > 0)
            try std.fmt.allocPrint(alloc, "{s}x:{s}@{s}/git/{s}.git", .{ scheme, token, hostpart, name })
        else
            try std.fmt.allocPrint(alloc, "{s}{s}/git/{s}.git", .{ scheme, hostpart, name });
    };

    const mirror = try std.fs.path.join(alloc, &.{ home, ".work", "repos", try std.fmt.allocPrint(alloc, "{s}.git", .{name}) });
    Io.Dir.cwd().createDirPath(io, mirror) catch {};
    const gd = try std.fmt.allocPrint(alloc, "--git-dir={s}", .{mirror});
    const wt = try std.fmt.allocPrint(alloc, "--work-tree={s}", .{abs});

    _ = std.process.run(alloc, io, .{ .argv = &.{ "git", gd, "init", "-q", "-b", "main" } }) catch {};
    _ = std.process.run(alloc, io, .{ .argv = &.{ "git", gd, "config", "user.name", "work" } }) catch {};
    _ = std.process.run(alloc, io, .{ .argv = &.{ "git", gd, "config", "user.email", "deploy@workbooks.local" } }) catch {};
    _ = std.process.run(alloc, io, .{ .argv = &.{ "git", gd, wt, "add", "-A" } }) catch {};
    _ = std.process.run(alloc, io, .{ .argv = &.{ "git", gd, wt, "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "deploy" } }) catch {};

    const push = std.process.run(alloc, io, .{ .argv = &.{ "git", gd, "push", "-f", remote, "HEAD:main" } }) catch {
        log.err(try std.fmt.allocPrint(alloc, "git push failed \u{2014} is the nexus reachable at {s} and are you logged in?", .{base}));
        return 1;
    };

    if (push.term == .exited and push.term.exited == 0) {
        log.ok(try std.fmt.allocPrint(alloc, "deployed \u{2192} {s}/{s}/", .{ base, name }));
        return 0;
    }

    log.err(try std.fmt.allocPrint(alloc, "deploy failed:\n{s}", .{push.stderr}));
    return 1;
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

pub fn apply(io: Io, alloc: std.mem.Allocator, home: []const u8, file: []const u8) !u8 {
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
    if (eql(place, "cloud")) return applyCloud(io, alloc, home, src);
    if (eql(place, "desktop")) return applyDesktop(io, alloc, src);
    return applyLocal(io, alloc, src);
}

// Desktop apply (Worktop): build the self-contained single binary — Burrito wraps the assembled OTP
// release (ERTS + BEAM + host-native NIFs) into ONE `nexus` executable that boots a Nexus headless
// with no VM/container. The build contract lives in the runtime's mix project (`mix release worktop`
// — ONE source of truth); the CLI invokes it rather than reimplementing Burrito here. Run from the
// runtime (the nexus mix project). Requires Zig 0.15.2 (Burrito's pinned wrapper toolchain).
fn applyDesktop(io: Io, alloc: std.mem.Allocator, src: []const u8) !u8 {
    _ = src;
    log.step("desktop target — building the Worktop self-contained binary (Burrito-wrapped OTP release, no VM)");

    // MIX_ENV=prod so the wrap bundles the production release; --overwrite rebuilds in place. Shelled
    // via `sh -c` so MIX_ENV is set for the child (mirrors the deploy bridge indirection of applyLocal).
    const r = std.process.run(alloc, io, .{ .argv = &.{ "sh", "-c", "MIX_ENV=prod mix release worktop --overwrite" } }) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "could not invoke the Worktop build ({s}) — run from the runtime (the nexus mix project); Burrito needs Zig 0.15.2 + xz in PATH", .{@errorName(e)}));
        return 1;
    };
    if (r.term == .exited and r.term.exited == 0) {
        log.print("{s}", .{r.stdout});
        const bin = "burrito_out/worktop_host";
        // Record the target so status/down know this is a locally-built binary (not a provisioned host).
        try writeState(io, alloc, "desktop", "", "", "burrito");
        log.ok(try std.fmt.allocPrint(alloc, "built {s} — boot it headless: WB_SERVE=1 PORT=<port> WB_DATA=<dir> ./{s} start  (then GET /health)", .{ bin, bin }));
        return 0;
    }
    log.err(try std.fmt.allocPrint(alloc, "Worktop build failed:\n{s}{s}", .{ r.stdout, r.stderr }));
    return 1;
}

// Cloud apply: POST the runtime config to the control plane's provisioner (Fly app+machine + CP
// registry — all server-side). The CLI only carries the request + the login token. Records the
// provisioned nexus in .work/runtime.state so verify/status/down can find it.
fn applyCloud(io: Io, alloc: std.mem.Allocator, home: []const u8, src: []const u8) !u8 {
    const c = context.cred(io, alloc, home) orelse {
        log.err("cloud apply needs a control-plane login — run `work login` first");
        return 1;
    };

    const name = attr(src, "app", "");
    const region = attr(src, "region", "");
    const plan = attr(src, "plan", "");
    const body = try std.fmt.allocPrint(alloc,
        \\{{"name":"{s}","region":"{s}","plan":"{s}"}}
    , .{ name, region, plan });

    const url = try std.fmt.allocPrint(alloc, "{s}/api/platform/nexuses", .{c.url});
    log.step(try std.fmt.allocPrint(alloc, "provisioning via {s}", .{c.url}));

    const res = cloudapi.request(io, alloc, .POST, url, c.token, body) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "control plane unreachable ({s})", .{@errorName(e)}));
        return 1;
    };

    if (res.status != 200 and res.status != 201) {
        log.err(try std.fmt.allocPrint(alloc, "provision failed (HTTP {d}): {s}", .{ res.status, res.body }));
        return 1;
    }

    const id = cloudapi.jsonField(res.body, "id") orelse "";
    const nx_url = cloudapi.jsonField(res.body, "url") orelse "";
    const machine = cloudapi.jsonField(res.body, "fly_machine") orelse "";
    try writeState(io, alloc, "cloud", id, nx_url, machine);
    log.ok(try std.fmt.allocPrint(alloc, "nexus provisioned \u{b7} {s} \u{b7} {s}", .{ id, nx_url }));
    log.step("`work deploy verify` to health-check it");
    return 0;
}

// Local apply: boot the one OCI runtime image in a krunvm microVM. The boot contract lives in the
// nexus (Nexus.Deploy.local → Nexus.Deploy.Machine, ONE source of truth); the CLI invokes it through
// the runtime's deploy entrypoint rather than reimplementing krunvm here.
fn applyLocal(io: Io, alloc: std.mem.Allocator, src: []const u8) !u8 {
    const image = attr(src, "image", "");
    log.step("local target — booting the nexus runtime in a vfkit microVM (real virtio-net NIC)");

    const argv: []const []const u8 = if (image.len > 0)
        &.{ "mix", "nexus.deploy.local", image }
    else
        &.{ "mix", "nexus.deploy.local" };

    const r = std.process.run(alloc, io, .{ .argv = argv }) catch |e| {
        log.err(try std.fmt.allocPrint(alloc, "could not invoke the deploy bridge ({s}) — run from the runtime, or `work deploy init` a cloud target", .{@errorName(e)}));
        return 1;
    };
    if (r.term == .exited and r.term.exited == 0) {
        log.print("{s}", .{r.stdout});
        // vfkit NAT gives the guest its own IP, so the nexus is at http://<guestIP>:4000 (not
        // localhost). Capture the URL the bridge printed so verify/status/down target the right host.
        const url = firstUrl(r.stdout) orelse "";
        try writeState(io, alloc, "local", "", url, "vfkit");
        if (url.len > 0) log.ok(try std.fmt.allocPrint(alloc, "running at {s} — `work deploy verify`", .{url}));
        return 0;
    }
    log.err(try std.fmt.allocPrint(alloc, "local boot failed:\n{s}{s}", .{ r.stdout, r.stderr }));
    return 1;
}

// Pull the first `http://…`/`https://…` token out of text (the booted nexus URL the bridge prints).
fn firstUrl(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "http") orelse return null;
    var end = at;
    while (end < text.len and text[end] != ' ' and text[end] != '\n' and text[end] != '\r' and text[end] != '\t') end += 1;
    return if (end > at + 7) text[at..end] else null;
}

/// `work deploy verify [--nexus <name>]` — health-probe a running nexus. Resolves the target nexus
/// (by name, else the active context), GETs `<base>/health`, and reports. Real, no scaffolding.
// Resolve which nexus to probe: an explicit `--nexus <name>` wins; otherwise prefer the URL `apply`
// recorded in .work/runtime.state (e.g. a vfkit local nexus at its NAT guest IP, not localhost);
// otherwise the active context's nexus.
fn resolveBase(io: Io, alloc: std.mem.Allocator, home: []const u8, nexus_name: []const u8) ![]const u8 {
    if (nexus_name.len > 0) return context.nexusByName(io, alloc, home, nexus_name);
    if (readState(io, alloc)) |state| {
        const url = blockAttr(state, "runtime do", "url", "");
        if (url.len > 0) return url;
    }
    return context.nexusUrl(io, alloc, home);
}

pub fn verify(io: Io, alloc: std.mem.Allocator, home: []const u8, nexus_name: []const u8) !u8 {
    const base = try resolveBase(io, alloc, home, nexus_name);

    log.prompt(try std.fmt.allocPrint(alloc, "work deploy verify {s}", .{base}));
    const token = if (context.cred(io, alloc, home)) |c| c.token else "";
    const url = try std.fmt.allocPrint(alloc, "{s}/health", .{base});

    if (cloudapi.request(io, alloc, .GET, url, token, null)) |res| {
        if (res.status == 200) {
            log.ok(try std.fmt.allocPrint(alloc, "healthy \u{b7} {s} (HTTP 200)", .{base}));
            return 0;
        }
        log.err(try std.fmt.allocPrint(alloc, "unhealthy \u{b7} {s} returned HTTP {d}", .{ base, res.status }));
        return 1;
    } else |e| {
        log.err(try std.fmt.allocPrint(alloc, "unreachable \u{b7} {s} ({s}) \u{2014} is the nexus up?", .{ base, @errorName(e) }));
        return 1;
    }
}

/// `work deploy status [--nexus <name>]` — inspect the target: the resolved nexus, its health, and
/// the local `deployment.work` engine-place (if present). Read-only.
pub fn status(io: Io, alloc: std.mem.Allocator, home: []const u8, nexus_name: []const u8) !u8 {
    const base = try resolveBase(io, alloc, home, nexus_name);

    log.prompt("work deploy status");
    log.step(try std.fmt.allocPrint(alloc, "nexus {s}", .{base}));

    if (fs.readFile(io, alloc, "deployment.work")) |src| {
        log.step(try std.fmt.allocPrint(alloc, "config \u{b7} engine-place={s} \u{b7} tenancy={s} \u{b7} database={s}", .{
            attr(src, "engine-place", "local"),
            attr(src, "tenancy-mode", "single"),
            attr(src, "database", "sqlite"),
        }));
    } else |_| log.step("no local deployment.work (run `work deploy init`)");

    const token = if (context.cred(io, alloc, home)) |c| c.token else "";
    const url = try std.fmt.allocPrint(alloc, "{s}/health", .{base});
    if (cloudapi.request(io, alloc, .GET, url, token, null)) |res| {
        if (res.status == 200) log.ok("health 200 \u{b7} up") else log.step(try std.fmt.allocPrint(alloc, "health HTTP {d}", .{res.status}));
    } else |_| log.step("health unreachable \u{b7} down");
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

test "desktop (Worktop) is a valid engine-place, single-user only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A coherent desktop config (single-user, local-fs, sqlite, trusted) → no issues.
    const ok = "deploy do\n engine-place=\"desktop\" tenancy-mode=\"single\" storage=\"local-fs\" database=\"sqlite\" auth=\"trusted\"\nend";
    try std.testing.expectEqual(@as(usize, 0), (try validate(a, ok)).len);

    // desktop can't be multi-tenant (the trust boundary is the machine) → flagged.
    const multi = "deploy do\n engine-place=\"desktop\" tenancy-mode=\"multi\"\nend";
    try std.testing.expect((try validate(a, multi)).len >= 1);

    // desktop is a recognized place for `deploy init`.
    try std.testing.expect(isPlace("desktop"));
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
