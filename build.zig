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
        .path = .{ .path = "tigerbeetle-io/src/io.zig" },
    };

    const exe = b.addExecutable("layerz", "src/main.zig");
    exe.linkLibC();
    exe.addIncludeDir("src/include");
    exe.linkSystemLibraryName("evdev");
    exe.addPackage(tigerbeetle);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const latency = b.addExecutable("latency", "src/latency.zig");
    latency.linkLibC();
    latency.addIncludeDir("src/include");
    latency.setTarget(target);
    // We want the latency measurement tool to be as fast as possible,
    // and to have it's performance constistent over runs.
    latency.setBuildMode(std.builtin.Mode.ReleaseFast);
    // latency.setBuildMode(std.builtin.Mode.Debug);
    latency.install();

    const tests = b.addTest("src/layerz.zig");
    tests.addIncludeDir("src/include");
    b.step("test", "Tests").dependOn(&tests.step);
}
