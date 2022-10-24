const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const tigerbeetle = std.build.Pkg{
        .name = "tigerbeetle_io",
        .source = .{ .path = "tigerbeetle-io/src/io.zig" },
    };

    const exe = b.addExecutable("layerz", "src/main.zig");
    exe.linkLibC();
    exe.addIncludePath("src/include");
    // TODO: build libevdev from source
    exe.linkSystemLibraryName("evdev");
    exe.addPackage(tigerbeetle);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const latency = b.addExecutable("latency", "src/latency.zig");
    latency.linkLibC();
    latency.addIncludePath("src/include");
    latency.setTarget(target);
    // We want the latency measurement tool to be as fast as possible,
    // and to have it's performance constistent over runs.
    latency.setBuildMode(std.builtin.Mode.ReleaseFast);
    // latency.setBuildMode(std.builtin.Mode.Debug);
    latency.install();

    const all_tests = b.step("test", "Tests");
    const tests = b.addTest("src/layerz.zig");
    tests.linkLibC();
    tests.addIncludePath("src/include");
    all_tests.dependOn(&tests.step);

    // const scratch_tests = b.addTest("src/scratch.zig");
    // scratch_tests.linkLibC();
    // scratch_tests.addIncludePath("src/include");
    // all_tests.dependOn(&scratch_tests.step);
}
