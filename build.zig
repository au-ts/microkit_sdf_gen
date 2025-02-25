const std = @import("std");

const test_device_trees = .{
    "qemu_virt_aarch64",
    "odroidc4",
    "star64",
    "maaxboard",
};

const VERSION_FILE = "VERSION";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_bytes = try (try std.fs.cwd().openFile(VERSION_FILE, .{})).readToEndAlloc(b.allocator, 100);
    const version = try std.SemanticVersion.parse(version_bytes);

    const dtbzig_dep = b.dependency("dtb.zig", .{});
    const dtb_module = dtbzig_dep.module("dtb");

    const libfdt_dep = b.dependency("libfdt_c", .{});
    const libfdt = libfdt_dep.artifact("fdt");

    const sdf_module = b.addModule("sdf", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdf_module.addImport("dtb", dtb_module);
    sdf_module.linkLibrary(libfdt);
    sdf_module.addIncludePath(libfdt_dep.path("."));

    const dtb_step = b.step("dtbs", "Compile Device Tree Sources into .dtb");
    inline for (test_device_trees) |device_tree| {
        const dtc_cmd = b.addSystemCommand(&[_][]const u8{ "dtc", "-q", "-I", "dts", "-O", "dtb" });
        const device_tree_path = b.path(b.fmt("examples/dts/{s}.dts", .{device_tree}));
        dtc_cmd.addFileInput(device_tree_path);
        dtc_cmd.addFileArg(device_tree_path);
        const dtb = dtc_cmd.captureStdOut();
        dtb_step.dependOn(&b.addInstallFileWithDir(dtb, .{ .custom = "dtb" }, b.fmt("{s}.dtb", .{device_tree})).step);
    }

    const zig_example_step = b.step("zig_example", "Exmaples of using Zig bindings");
    const zig_example = b.addExecutable(.{
        .name = "zig_example",
        .root_source_file = b.path("examples/examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_example.linkLibrary(libfdt);
    zig_example.addIncludePath(libfdt_dep.path("."));
    // TODO: should these be runtime options instead?
    const zig_example_options = b.addOptions();
    zig_example_options.addOptionPath("sddf", b.path("sddf"));
    zig_example_options.addOption([]const u8, "dtbs", b.getInstallPath(.{ .custom = "dtb" }, ""));
    zig_example_options.addOption([]const u8, "data_output", b.getInstallPath(.prefix, ""));

    zig_example.root_module.addOptions("config", zig_example_options);
    zig_example.root_module.addImport("sdf", sdf_module);

    const zig_example_cmd = b.addRunArtifact(zig_example);
    if (b.args) |args| {
        zig_example_cmd.addArgs(args);
    }
    // In case any sDDF configuration files are changed
    _ = try zig_example_cmd.step.addDirectoryWatchInput(b.path("sddf"));
    zig_example_cmd.step.dependOn(dtb_step);

    zig_example_step.dependOn(&zig_example_cmd.step);
    const zig_example_install = b.addInstallArtifact(zig_example, .{});
    zig_example_step.dependOn(&zig_example_install.step);

    const csdfgen_module = b.addModule("csdfgen", .{
        .root_source_file = b.path("src/c/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    csdfgen_module.addIncludePath(b.path("src/c"));
    csdfgen_module.addImport("sdf", sdf_module);

    // Default to dynamic library for Darwin
    const csdfgen_default_linkage: std.builtin.LinkMode = if (target.result.os.tag.isDarwin()) .dynamic else .static;
    const csdfgen_linkage = b.option(std.builtin.LinkMode, "c-linkage", "Specify link mode of libcsdfgen") orelse csdfgen_default_linkage;
    const csdfgen = b.addLibrary(.{
        .name = "csdfgen",
        .root_module = csdfgen_module,
        .version = version,
        .linkage = csdfgen_linkage,
    });
    csdfgen.linkLibC();
    csdfgen.installHeader(b.path("src/c/sdfgen.h"), "sdfgen.h");
    csdfgen.bundle_compiler_rt = true;
    b.installArtifact(csdfgen);

    const c_step = b.step("c", "Library for C bindings");
    c_step.dependOn(b.getInstallStep());
    const csdfgen_emit = b.option([]const u8, "c-emit", "Specify libcsdfgen emit path/name") orelse null;
    if (csdfgen_emit) |name| {
        c_step.dependOn(&b.addInstallLibFile(csdfgen.getEmittedBin(), name).step);
    }

    const c_example = b.addExecutable(.{
        .name = "c_example",
        .target = target,
        .optimize = optimize,
    });
    c_example.addCSourceFile(.{ .file = b.path("examples/examples.c") });
    c_example.linkLibrary(csdfgen);
    c_example.linkLibrary(libfdt);
    c_example.linkLibC();
    c_example.addIncludePath(libfdt_dep.path("."));

    const c_example_step = b.step("c_example", "Run example program using C bindings");
    const c_example_cmd = b.addRunArtifact(c_example);
    // In case any sDDF configuration files are changed
    c_example_cmd.addDirectoryArg(b.path("sddf"));
    _ = try c_example_cmd.step.addDirectoryWatchInput(b.path("sddf"));
    c_example_step.dependOn(&c_example_cmd.step);

    const c_example_install = b.addInstallFileWithDir(c_example.getEmittedBin(), .bin, "c_example");

    // wasm executable
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "gui_sdfgen",
        .root_source_file = b.path("src/gui_sdfgen.zig"),
        .target = wasm_target,
        .optimize = .Debug,
        .strip = false,
    });

    wasm.root_module.addImport("dtb", dtb_module);
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{ "fetchInitInfo", "jsonToXml" };

    const wasm_step = b.step("wasm", "build wasm");

    const wasm_install = b.addInstallArtifact(wasm, .{});
    wasm_step.dependOn(&wasm_install.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.linkLibrary(libfdt);
    tests.addIncludePath(libfdt_dep.path("."));

    const test_options = b.addOptions();
    test_options.addOptionPath("c_example", .{ .cwd_relative = b.getInstallPath(.bin, c_example.name) });
    test_options.addOptionPath("test_dir", b.path("tests"));
    test_options.addOptionPath("sddf", b.path("sddf"));
    test_options.addOption([]const u8, "dtb", b.getInstallPath(.{ .custom = "dtb" }, ""));

    tests.root_module.addImport("sdf", sdf_module);
    tests.root_module.addOptions("config", test_options);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    run_tests.step.dependOn(&c_example_install.step);
    run_tests.step.dependOn(dtb_step);
    // In case any sDDF configuration files are changed
    _ = try test_step.addDirectoryWatchInput(b.path("sddf"));
}
