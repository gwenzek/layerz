const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    // const tigerbeetle = std.build.Pkg{
    //     .name = "tigerbeetle_io",
    //     .source = .{ .path = "tigerbeetle-io/src/io.zig" },
    // };

    const exe = b.addExecutable(.{
        .name = "layerz",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.linkLibC();
    exe.addIncludePath(.{ .path = "src/include" });
    // TODO: build libevdev from source
    exe.linkSystemLibraryName("evdev");
    // exe.addPackage(tigerbeetle);
    b.installArtifact(exe);

    const latency = b.addExecutable(.{
        .name = "latency",
        .root_source_file = .{ .path = "src/latency.zig" },
        .target = target,
        // We want the latency measurement tool to be as fast as possible,
        // and to have it's performance constistent over runs.
        .optimize = std.builtin.Mode.ReleaseFast,
        .link_libc = true,
    });
    latency.addIncludePath(.{ .path = "src/include" });
    b.installArtifact(latency);

    var test_filter = b.option([]const u8, "test-filter", "Filter for test");
    const all_tests = b.step("test", "Tests");
    const layerz_tests = b.addTest(.{ .root_source_file = .{ .path = "src/layerz.zig" }, .link_libc = true, .filter = test_filter });
    layerz_tests.addIncludePath(.{ .path = "src/include" });
    const run_layerz_tests = b.addRunArtifact(layerz_tests);

    all_tests.dependOn(&run_layerz_tests.step);
    all_tests.dependOn(&exe.step);
    all_tests.dependOn(&latency.step);

    // const scratch_tests = b.addTest("src/scratch.zig");
    // scratch_tests.linkLibC();
    // scratch_tests.addIncludePath("src/include");
    // all_tests.dependOn(&scratch_tests.step);
}
