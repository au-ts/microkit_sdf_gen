const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "fdt",
        .target = target,
        .optimize = optimize,
    });

    lib.addCSourceFiles(.{
        .files = &.{
            "fdt.c",
            "fdt_ro.c",
            "fdt_wip.c",
            "fdt_sw.c",
            "fdt_rw.c",
            "fdt_strerror.c",
            "fdt_empty_tree.c",
            "fdt_addresses.c",
            "fdt_overlay.c",
            "fdt_check.c",
        },
        .flags = &.{"-std=c99"},
    });

    lib.addIncludePath(b.path("."));
    b.installArtifact(lib);

    // Create an example Zig executable that uses libfdt for sanity checking
    const exe = b.addExecutable(.{
        .name = "example",
        .target = target,
        .optimize = optimize,
    });
    const main_module = b.addModule("main", .{ .root_source_file = b.path("main.zig") });
    exe.root_module.addImport("main", main_module);
    exe.linkLibrary(lib);
    exe.addIncludePath(b.path("."));
    b.installArtifact(exe);

    // Default step
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
