//! `work` — the one Workbooks CLI. One Zig source, native + wasm32-wasip1 (it runs on a laptop, in
//! CI, and inside the agent's wasm sandbox). Author, build, run, deploy `.work` workbooks. Minimal,
//! DRY, no dead OQL/kernel concepts — built for the literate `.work` model.
const std = @import("std");
const log = @import("log.zig");
const work = @import("work.zig");
const author = @import("author.zig");
const weave = @import("weave.zig");
const dev = @import("dev.zig");
const deploy = @import("deploy.zig");
const newcmd = @import("new.zig");
const context = @import("context.zig");
const conformance = @import("conformance.zig");
test {
    _ = work;
    _ = conformance;
    _ = deploy;
}

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    log.setIo(init.io);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // program name
    const verb = it.next() orelse "help";
    const io = init.io;
    const alloc = init.arena.allocator();
    const home = init.environ_map.get("HOME") orelse ".";

    if (eql(verb, "check")) {
        std.process.exit(try author.check(io, alloc, it.next() orelse "."));
    } else if (eql(verb, "structure")) {
        std.process.exit(try author.structure(io, alloc, it.next() orelse "."));
    } else if (eql(verb, "lint")) {
        std.process.exit(try author.lint(io, alloc, it.next() orelse "."));
    } else if (eql(verb, "why")) {
        const name = stripColon(it.next() orelse "");
        std.process.exit(try author.why(io, alloc, it.next() orelse ".", name));
    } else if (eql(verb, "near")) {
        const name = stripColon(it.next() orelse "");
        std.process.exit(try author.near(io, alloc, it.next() orelse ".", name));
    } else if (eql(verb, "wit")) {
        const name = stripColon(it.next() orelse "");
        std.process.exit(try author.wit(io, alloc, it.next() orelse ".", name));
    } else if (eql(verb, "new")) {
        const troot = init.environ_map.get("WB_TEMPLATES") orelse "templates";
        const tmpl = it.next() orelse "";
        std.process.exit(try newcmd.new(io, alloc, troot, tmpl, it.next() orelse ""));
    } else if (eql(verb, "weave")) {
        const d = it.next() orelse ".";
        const o = it.next() orelse "workbook.html";
        std.process.exit(try weave.weave(io, alloc, d, o));
    } else if (eql(verb, "graph")) {
        const d = it.next() orelse ".";
        const o = it.next() orelse "graph.html";
        std.process.exit(try author.graph(io, alloc, d, o));
    } else if (eql(verb, "dev")) {
        const d = it.next() orelse ".";
        std.process.exit(try dev.dev(io, alloc, d, it.next() orelse "workbook.html"));
    } else if (eql(verb, "deploy")) {
        const sub = it.next() orelse "";
        if (eql(sub, "init")) {
            const place = it.next() orelse "local";
            std.process.exit(try deploy.init(io, alloc, place, it.next() orelse ".", false));
        } else if (eql(sub, "validate")) {
            std.process.exit(try deploy.validateVerb(io, alloc, it.next() orelse "deployment.work"));
        } else if (eql(sub, "apply")) {
            std.process.exit(try deploy.apply(io, alloc, it.next() orelse "deployment.work"));
        } else {
            log.err("usage: work deploy init|validate|apply");
            std.process.exit(1);
        }
    } else if (eql(verb, "ctx")) {
        const sub = it.next() orelse "list";
        if (eql(sub, "use")) {
            std.process.exit(try context.ctxUse(io, alloc, home, it.next() orelse ""));
        } else if (eql(sub, "set")) {
            const name = it.next() orelse "";
            const f = flags(alloc, &it);
            std.process.exit(try context.ctxSet(io, alloc, home, name, f.nexus, f.org, f.workspace));
        } else {
            std.process.exit(try context.ctxList(io, alloc, home));
        }
    } else if (eql(verb, "nexus")) {
        std.process.exit(try context.nexusVerb(io, alloc, home, it.next() orelse ""));
    } else if (eql(verb, "whoami")) {
        std.process.exit(try context.whoami(io, alloc, home));
    } else if (eql(verb, "login")) {
        const a1 = it.next() orelse "";
        var url: []const u8 = "";
        var token: []const u8 = "";
        if (eql(a1, "--token")) {
            token = it.next() orelse "";
        } else {
            url = a1;
            if (eql(it.next() orelse "", "--token")) token = it.next() orelse "";
        }
        std.process.exit(try context.login(io, alloc, home, url, token));
    } else if (eql(verb, "version") or eql(verb, "--version")) {
        log.print("work {s}\n", .{version});
    } else if (eql(verb, "help") or eql(verb, "--help")) {
        help();
    } else {
        log.err("unknown command");
        log.step("run `work help` for the surface");
        std.process.exit(1);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn stripColon(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == ':') s[1..] else s;
}

const Flags = struct { nexus: []const u8 = "", org: []const u8 = "", workspace: []const u8 = "" };

fn flags(alloc: std.mem.Allocator, it: anytype) Flags {
    _ = alloc;
    var f: Flags = .{};
    while (it.next()) |tok| {
        const val = it.next() orelse break;
        if (eql(tok, "--nexus")) f.nexus = val
        else if (eql(tok, "--org")) f.org = val
        else if (eql(tok, "--workspace")) f.workspace = val;
    }
    return f;
}

const Group = struct { name: []const u8, blurb: []const u8, verbs: []const [2][]const u8 };

const groups = [_]Group{
    .{ .name = "author", .blurb = "read & verify .work trees (local)", .verbs = &.{
        .{ "check [dir]", "resolve references + audit capabilities" },
        .{ "structure [dir]", "list the units in the tree" },
        .{ "why/near/wit :unit", "code-graph deps + the generated WIT world" },
    } },
    .{ .name = "build", .blurb = "weave & run", .verbs = &.{
        .{ "new <template> [dest]", "scaffold an example project to own + edit" },
        .{ "weave <dir> <out>", "weave a tree into one self-contained html" },
        .{ "graph <dir> <out>", "render the code graph as a workbook" },
        .{ "dev <dir>", "watch & re-weave on change (+ nexus hot-swap)" },
    } },
    .{ .name = "deploy", .blurb = "stand up a runtime, local or cloud", .verbs = &.{
        .{ "deploy init|validate|apply", "scaffold · check · deploy the .work config" },
        .{ "deploy verify|status|down", "health · inspect · teardown" },
    } },
    .{ .name = "platform", .blurb = "identity, contexts, the control plane", .verbs = &.{
        .{ "ctx · nexus <url>", "manage targets · point at an engine" },
        .{ "login · whoami", "authenticate · show identity" },
    } },
};

fn help() void {
    log.prompt("work");
    log.print("  {s}the one Workbooks CLI \u{2014} author, build, run, deploy{s}\n\n", .{ log.dim_c, log.reset });

    for (groups) |g| {
        log.print("{s}{s}{s}  {s}{s}{s}\n", .{ log.cmd_c, g.name, log.reset, log.dim_c, g.blurb, log.reset });
        for (g.verbs) |v| {
            log.print("  {s}{s: <26}{s}  {s}\n", .{ log.path_c, v[0], log.reset, v[1] });
        }
        log.out("\n");
    }
    log.print("{s}runs native + in the wasm agent sandbox \u{b7} --json --no-color{s}\n", .{ log.dim_c, log.reset });
}
