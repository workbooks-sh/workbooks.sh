//! `work secret` — the local side of the secrets model (see the docs' "Secrets &
//! configuration"). Secrets are NEVER in source: `set` stores a value in the macOS
//! Keychain (service "workbooks"), `get` reads it back, `delete` removes it, `list`
//! shows the workbook's declared `secrets do … end` schema + which keys are set
//! (masked), and `schema` emits a varlock `.env.schema` whose values resolve via
//! `work secret get` — so `varlock run` injects them and the runtime reads them
//! through `Nexus.Secrets`. The agent only ever sees the schema, never a value.
//!
//! Host-only: the wasm sandbox has no Keychain or process exec, so the keychain
//! verbs are comptime-elided there and report that they need the host.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const work = @import("work.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");

const is_host = builtin.target.os.tag != .wasi;
const SERVICE = "workbooks";

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn secret(io: Io, alloc: std.mem.Allocator, sub: []const u8, arg: []const u8) !u8 {
    if (eql(sub, "set")) return set(io, alloc, arg);
    if (eql(sub, "get")) return get(io, alloc, arg);
    if (eql(sub, "delete") or eql(sub, "rm")) return del(io, alloc, arg);
    if (eql(sub, "list") or eql(sub, "")) return list(io, alloc, if (arg.len == 0) "." else arg);
    if (eql(sub, "schema")) return schema(io, alloc, if (arg.len == 0) "." else arg);
    log.err("usage: work secret set|get|delete <NAME>  ·  list|schema [dir]");
    return 1;
}

// ── keychain verbs (host-only) ────────────────────────────────────────────────
fn set(io: Io, alloc: std.mem.Allocator, name: []const u8) !u8 {
    if (name.len == 0) {
        log.err("usage: work secret set <NAME>");
        return 1;
    }
    if (is_host) {
        log.prompt(try std.fmt.allocPrint(alloc, "work secret set {s}", .{name}));
        // `-w` with no value → security prompts on the terminal (no value in argv/ps).
        var child = try std.process.spawn(io, .{
            .argv = &.{ "security", "add-generic-password", "-U", "-s", SERVICE, "-a", name, "-w" },
        });
        const term = child.wait(io) catch return hostErr();
        if (term == .exited and term.exited == 0) {
            log.ok(try std.fmt.allocPrint(alloc, "stored {s} in the macOS Keychain", .{name}));
            return 0;
        }
        log.err("could not store the secret");
        return 1;
    } else return hostErr();
}

fn get(io: Io, alloc: std.mem.Allocator, name: []const u8) !u8 {
    if (name.len == 0) {
        log.err("usage: work secret get <NAME>");
        return 1;
    }
    if (is_host) {
        const res = std.process.run(alloc, io, .{
            .argv = &.{ "security", "find-generic-password", "-s", SERVICE, "-a", name, "-w" },
        }) catch return hostErr();
        if (res.term == .exited and res.term.exited == 0) {
            log.out(std.mem.trimEnd(u8, res.stdout, "\n"));
            log.out("\n");
            return 0;
        }
        log.err(try std.fmt.allocPrint(alloc, "{s} is not set (work secret set {s})", .{ name, name }));
        return 1;
    } else return hostErr();
}

fn del(io: Io, alloc: std.mem.Allocator, name: []const u8) !u8 {
    if (name.len == 0) {
        log.err("usage: work secret delete <NAME>");
        return 1;
    }
    if (is_host) {
        const res = std.process.run(alloc, io, .{
            .argv = &.{ "security", "delete-generic-password", "-s", SERVICE, "-a", name },
        }) catch return hostErr();
        if (res.term == .exited and res.term.exited == 0) {
            log.ok(try std.fmt.allocPrint(alloc, "deleted {s}", .{name}));
            return 0;
        }
        log.err(try std.fmt.allocPrint(alloc, "{s} was not set", .{name}));
        return 1;
    } else return hostErr();
}

fn isSet(io: Io, alloc: std.mem.Allocator, name: []const u8) bool {
    if (!is_host) return false;
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "security", "find-generic-password", "-s", SERVICE, "-a", name, "-w" },
    }) catch return false;
    return res.term == .exited and res.term.exited == 0;
}

// ── schema-driven verbs (work everywhere) ─────────────────────────────────────
const Decl = struct { name: []const u8, desc: []const u8 };

fn list(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u8 {
    const decls = try readSchema(io, alloc, dir);
    log.prompt(try std.fmt.allocPrint(alloc, "work secret list {s}", .{dir}));
    if (decls.len == 0) {
        log.step("no `secrets do … end` block in this workbook");
        return 0;
    }
    for (decls) |d| {
        const mark = if (isSet(io, alloc, d.name)) "\u{2713} set " else "\u{00b7} unset";
        log.print("  {s}  {s: <28}{s}\n", .{ mark, d.name, d.desc });
    }
    if (!is_host) log.step("set/check needs the host (no Keychain in the wasm sandbox)");
    return 0;
}

fn schema(io: Io, alloc: std.mem.Allocator, dir: []const u8) !u8 {
    const decls = try readSchema(io, alloc, dir);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "# @generated by `work secret schema` — varlock .env.schema. Values resolve\n# from the OS Keychain via `work secret get`; never edit values here.\n# @defaultSensitive=true @defaultRequired=true\n\n");
    for (decls) |d| {
        if (d.desc.len != 0) try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "# {s}\n", .{d.desc}));
        try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}=exec(`work secret get {s}`) # @sensitive @required\n\n", .{ d.name, d.name }));
    }
    const out = try std.fs.path.join(alloc, &.{ dir, ".env.schema" });
    try fs.writeFile(io, out, buf.items);
    log.ok(try std.fmt.allocPrint(alloc, "{s} \u{b7} {d} secret(s)", .{ out, decls.len }));
    return 0;
}

// Read the `secrets do … end` block across the workbook's .work files. Each non-empty
// body line is `NAME [description]`.
fn readSchema(io: Io, alloc: std.mem.Allocator, dir: []const u8) ![]const Decl {
    var decls: std.ArrayList(Decl) = .empty;
    const files = try fs.workFiles(io, alloc, dir);
    for (files) |f| {
        const src = fs.readFile(io, alloc, f) catch continue;
        const nodes = try work.parse(alloc, src);
        for (nodes) |n| {
            if (n.type != .code or !eql(n.kind, "secrets")) continue;
            var lines = std.mem.splitScalar(u8, n.body, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
                try decls.append(alloc, .{
                    .name = line[0..sp],
                    .desc = std.mem.trim(u8, line[@min(sp, line.len)..], " \t\""),
                });
            }
        }
    }
    return decls.items;
}

fn hostErr() u8 {
    log.err("`work secret` runs on the host — the Keychain isn't reachable from the wasm sandbox");
    return 1;
}
