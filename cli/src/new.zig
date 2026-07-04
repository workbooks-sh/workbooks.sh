//! `work new <template> [dest]` — scaffold a project from a template (a runnable example app under
//! `templates/`, or `$WB_TEMPLATES`). Copies the template's `.work` files (and assets) into `dest`
//! so the author owns the copy and replaces the logic. Templates are scaffold-and-own — NOT toolkits
//! (which are imported + depended on). With no template, lists what's available.
const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const log = @import("log.zig");

pub fn new(io: Io, alloc: std.mem.Allocator, root: []const u8, template: []const u8, dest_in: []const u8) !u8 {
    if (template.len == 0) {
        log.prompt("work new");
        log.step("usage: work new <template> [dest] \u{2014} scaffold an example project to own + edit");
        try listTemplates(io, alloc, root);
        return 0;
    }

    const tdir = try std.fs.path.join(alloc, &.{ root, template });
    const files = try fs.allFiles(io, alloc, tdir);
    if (files.len == 0) {
        log.err(try std.fmt.allocPrint(alloc, "no template \u{201c}{s}\u{201d} under {s}/", .{ template, root }));
        try listTemplates(io, alloc, root);
        return 1;
    }

    const dest = if (dest_in.len == 0) template else dest_in;
    log.prompt(try std.fmt.allocPrint(alloc, "work new {s} {s}", .{ template, dest }));

    var n: usize = 0;
    for (files) |rel| {
        const src = try std.fs.path.join(alloc, &.{ tdir, rel });
        const data = fs.readFile(io, alloc, src) catch continue;
        const out = try std.fs.path.join(alloc, &.{ dest, rel });
        if (std.fs.path.dirname(out)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
        try fs.writeFile(io, out, data);
        n += 1;
    }

    log.ok(try std.fmt.allocPrint(alloc, "scaffolded {d} files \u{2192} {s}/", .{ n, dest }));
    log.step(try std.fmt.allocPrint(alloc, "cd {s} \u{b7} read TEMPLATE.work \u{b7} `work weave .` \u{b7} replace the server/client/resource blocks with your own", .{dest}));
    return 0;
}

fn listTemplates(io: Io, alloc: std.mem.Allocator, root: []const u8) !void {
    const files = try fs.allFiles(io, alloc, root);
    var seen: std.ArrayList([]const u8) = .empty;

    for (files) |rel| {
        const name = firstSeg(rel);
        var have = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, name)) have = true;
        }
        if (!have) {
            try seen.append(alloc, name);
            log.print("  {s}{s}{s}\n", .{ log.path_c, name, log.reset });
        }
    }

    if (seen.items.len == 0) log.step("(no templates found \u{2014} set $WB_TEMPLATES or run from a tree with templates/)");
}

fn firstSeg(p: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, p, '/') orelse return p;
    return p[0..i];
}
