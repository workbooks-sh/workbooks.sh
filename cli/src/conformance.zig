//! Conformance: the Zig parser must produce the SAME units as the golden (generated from the Elixir
//! `work_core` reference parser). This is the zero-drift mechanism — ONE `.work` spec (cli/corpus/),
//! two thin implementations (Elixir for the server, Zig for the CLI/sandbox), neither allowed to
//! silently diverge. If this test or the matching Elixir test goes red, the parsers disagree.
const std = @import("std");
const work = @import("work.zig");

const corpus = [_][]const u8{
    @embedFile("corpus/agent.work"),
    @embedFile("corpus/langs.work"),
    @embedFile("corpus/nested.work"),
    @embedFile("corpus/store.work"),
    @embedFile("corpus/refs.work"),
};
const golden = @embedFile("corpus/units.golden");
const refs_golden = @embedFile("corpus/refs.golden");

test "parser conforms to the .work golden (matches work_core)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    for (corpus) |src| {
        const nodes = try work.parse(a, src);
        for (nodes) |n| if (n.type == .code and n.name.len > 0) {
            try lines.append(a, try std.fmt.allocPrint(a, "{s}|{s}|{s}", .{ n.name, n.kind, n.lang }));
        };
    }
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    const got = try std.mem.join(a, "\n", lines.items);
    const want = std.mem.trimEnd(u8, golden, "\n");

    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("\n--- GOLDEN ---\n{s}\n--- ZIG ---\n{s}\n", .{ want, got });
        return e;
    };
}

test "ref extraction conforms to the .work refs golden (matches work_core @ref_re)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var refs: std.ArrayList([]const u8) = .empty;
    for (corpus) |src| {
        const nodes = try work.parse(a, src);
        for (nodes) |n| for (n.refs) |r| try refs.append(a, r);
    }
    std.mem.sort([]const u8, refs.items, {}, lessThan);
    const got = try std.mem.join(a, "\n", refs.items);
    const want = std.mem.trimEnd(u8, refs_golden, "\n");

    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("\n--- REFS GOLDEN ---\n{s}\n--- ZIG ---\n{s}\n", .{ want, got });
        return e;
    };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}
