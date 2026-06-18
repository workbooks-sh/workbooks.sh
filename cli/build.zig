const std = @import("std");

// The one `work` CLI — one Zig source, native + wasm32-wasip1. Native builds the runnable binary;
// `-Dwasm` builds the wasm32-wasip1 module agents run inside the sandbox.
pub fn build(b: *std.Build) void {
    const wasm = b.option(bool, "wasm", "Build the wasm32-wasip1 module") orelse false;
    const host = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target = if (wasm)
        b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi })
    else
        host;

    const exe = b.addExecutable(.{
        .name = "work",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run work");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The toolchain as a wasm REACTOR (exported fns, no entry) — what nexus instantiates once and
    // calls many times. `zig build reactor` → zig-out/bin/work-toolchain.wasm.
    const reactor = b.addExecutable(.{
        .name = "work-toolchain",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    reactor.entry = .disabled;
    reactor.rdynamic = true;
    const reactor_step = b.step("reactor", "Build the wasm toolchain reactor");
    reactor_step.dependOn(&b.addInstallArtifact(reactor, .{}).step);
}
