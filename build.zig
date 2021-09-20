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

    const exe = b.addExecutable("layerz", "src/main.zig");
    exe.addIncludeDir("/usr/include/");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const latency = b.addExecutable("latency", "src/latency.zig");
    latency.addIncludeDir("/usr/include/");
    latency.setTarget(target);
    latency.setBuildMode(mode);
    latency.install();

    const tests = b.addTest("src/layerz.zig");
    tests.addIncludeDir("/usr/include/");
    b.step("test", "Tests").dependOn(&tests.step);
}
