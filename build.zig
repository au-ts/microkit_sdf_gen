const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dtbzig_dep = b.dependency("dtbzig", .{});

    const lib = b.addStaticLibrary(.{
        .name = "microkit_sdf_gen",
        .root_source_file = b.path("src/sdf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sdfgen_step = b.step("sdfgen", "Utility for testing and developing examples of SDF auto-generation");
    const sdfgen = b.addExecutable(.{
        .name = "sdfgen",
        .root_source_file = b.path("src/sdfgen.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We want to be able to import the 'dtb.zig' library as a module.
    const dtb_module = dtbzig_dep.module("dtb");
    sdfgen.root_module.addImport("dtb", dtb_module);

    const sdfgen_cmd = b.addRunArtifact(sdfgen);
    if (b.args) |args| {
        sdfgen_cmd.addArgs(args);
    }

    sdfgen_step.dependOn(&sdfgen_cmd.step);
    const sdfgen_install = b.addInstallArtifact(sdfgen, .{});
    sdfgen_step.dependOn(&sdfgen_install.step);

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_main_tests.step);

    const modsdf = b.addModule("sdf", .{ .root_source_file = b.path("src/sdf.zig") } );

    const pysdfgen_bin = b.option([]const u8, "pysdfgen-emit", "Name of pysdfgen library") orelse "pysdfgen.so";
    const pysdfgen = b.addSharedLibrary(.{
        .name = "pysdfgen",
        .root_source_file = b.path("python/sdfgen_module.zig"),
        .target = target,
        .optimize = optimize,
    });
    pysdfgen.linker_allow_shlib_undefined = true;
    pysdfgen.addIncludePath(.{ .cwd_relative = "/usr/include/python3.10" });
    pysdfgen.root_module.addImport("sdf", modsdf);
    pysdfgen.linkLibC();
    // TODO: should probably check if the library exists first...
    pysdfgen.linkSystemLibrary("python3");
    b.installArtifact(pysdfgen);

    const pysdfgen_step = b.step("pysdfgen", "Library for the Python sdfgen module");
    const pysdfgen_install = b.addInstallFileWithDir(pysdfgen.getEmittedBin(), .lib, pysdfgen_bin);
    pysdfgen_step.dependOn(&pysdfgen_install.step);

    const libsdfgen = b.addStaticLibrary(.{
        .name = "sdfgen",
        .root_source_file = b.path("src/c/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    libsdfgen.root_module.addImport("sdf", modsdf);

    const c_example_step = b.step("c", "Example of using libsdfgen with C");
    const c_example = b.addExecutable(.{
        .name = "c_example",
        .root_source_file = b.path("c/example.c"),
        .target = target,
        .optimize = optimize,
    });
    c_example.linkLibrary(libsdfgen);
    c_example.addIncludePath(b.path("src/c"));
    const c_example_cmd = b.addRunArtifact(c_example);

    c_example_step.dependOn(&c_example_cmd.step);
    const c_example_install = b.addInstallArtifact(c_example, .{});
    c_example_step.dependOn(&c_example_install.step);
}
