const std = @import("std");
const mod = @import("sdf");
const mod_sdf = mod.sdf;

const SystemDescription = mod_sdf.SystemDescription;
const ProtectionDomain = SystemDescription.ProtectionDomain;
const MemoryRegion = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Interrupt = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;
const VirtualMachine = SystemDescription.VirtualMachine;
const Vmm = mod.Vmm;

const allocator = std.testing.allocator;

const config = @import("config");

fn readTestFile(test_path: []const u8) ![]const u8 {
    const test_dir = try std.fs.openDirAbsolute(config.test_dir, .{});
    const test_file = try test_dir.openFile(test_path, .{});
    const test_file_size = (try test_file.stat()).size;
    return try test_file.reader().readAllAlloc(
        allocator,
        test_file_size,
    );
}

test "rounding" {
    const sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);
    const arch = sdf.arch;

    try std.testing.expectEqual(arch.roundDownToPage(0x1000), 0x1000);
    try std.testing.expectEqual(arch.roundDownToPage(0x1001), 0x1000);
    try std.testing.expectEqual(arch.roundDownToPage(0x1100), 0x1000);

    try std.testing.expectEqual(arch.roundUpToPage(0x1000), 0x1000);
    try std.testing.expectEqual(arch.roundUpToPage(0x1001), 0x2000);
    try std.testing.expectEqual(arch.roundUpToPage(0x1100), 0x2000);
}

test "basic" {
    var sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);

    var pd = ProtectionDomain.create(allocator, "hello", "hello.elf", .{});

    sdf.addProtectionDomain(&pd);

    const expected = try readTestFile("basic.system");
    const output = try sdf.render();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}

test "PD + MR + mappings + channel" {
    var sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);
    const mr = MemoryRegion.create(allocator, "test", 0x1000, .{ .page_size = .small });
    sdf.addMemoryRegion(mr);

    const image = "hello.elf";
    var pd1 = ProtectionDomain.create(allocator, "hello-1", image, .{});
    _ = try pd1.addIrq(.create(33, .{}));
    pd1.addMap(.create(allocator, mr, 0x400000000, .r, .{}));
    pd1.addMap(.create(allocator, mr, 0x500000000, .x, .{}));
    pd1.addMap(.create(allocator, mr, 0x600000000, .rw, .{}));
    pd1.addMap(.create(allocator, mr, 0x700000000, .rx, .{}));
    pd1.addMap(.create(allocator, mr, 0x800000000, .wx, .{}));
    pd1.addMap(.create(allocator, mr, 0x900000000, .rwx, .{}));

    var pd2 = ProtectionDomain.create(allocator, "hello-2", image, .{});

    sdf.addProtectionDomain(&pd1);
    sdf.addProtectionDomain(&pd2);

    sdf.addChannel(try Channel.create(&pd1, &pd2, .{}));

    const expected = try readTestFile("pd_mr_map_channel.system");
    const output = try sdf.render();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}

test "fixed channel" {
    var sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);

    var pd1 = ProtectionDomain.create(allocator, "hello-1", "hello.elf", .{});
    var pd2 = ProtectionDomain.create(allocator, "hello-2", "hello.elf", .{});

    sdf.addProtectionDomain(&pd1);
    sdf.addProtectionDomain(&pd2);

    _ = try pd1.addIrq(.create(33, .{ .trigger = .level, .id = 0 }));

    sdf.addChannel(try Channel.create(&pd1, &pd2, .{
        .pd_a_id = 3,
        .pd_b_id = 5,
    }));
    sdf.addChannel(try Channel.create(&pd1, &pd2, .{}));

    const expected = try readTestFile("pd_fixed_channel.system");
    const output = try sdf.render();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}

test "channels" {
    var sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);

    var pd1 = ProtectionDomain.create(allocator, "hello-1", "hello.elf", .{
        .priority = 3,
    });
    var pd2 = ProtectionDomain.create(allocator, "hello-2", "hello.elf", .{
        .priority = 2,
    });
    var pd3 = ProtectionDomain.create(allocator, "hello-3", "hello.elf", .{
        .priority = 1,
    });

    sdf.addProtectionDomain(&pd1);
    sdf.addProtectionDomain(&pd2);
    sdf.addProtectionDomain(&pd3);

    sdf.addChannel(try Channel.create(&pd1, &pd2, .{}));
    sdf.addChannel(try Channel.create(&pd1, &pd2, .{
        .pd_a_notify = false,
    }));
    sdf.addChannel(try Channel.create(&pd1, &pd2, .{
        .pd_b_notify = false,
    }));
    sdf.addChannel(try Channel.create(&pd1, &pd2, .{
        .pp = .a,
    }));
    sdf.addChannel(try Channel.create(&pd1, &pd2, .{
        .pp = .b,
    }));
    sdf.addChannel(try Channel.create(&pd1, &pd2, .{
        .pd_a_notify = false,
        .pp = .a,
    }));
    sdf.addChannel(try Channel.create(&pd3, &pd1, .{
        .pd_a_notify = false,
        .pd_b_notify = false,
        .pp = .b,
    }));

    const expected = try readTestFile("channels.system");
    const output = try sdf.render();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}

test "C example" {
    var example_process = std.process.Child.init(&.{ config.c_example, config.sddf }, allocator);

    example_process.stdin_behavior = .Ignore;
    example_process.stdout_behavior = .Pipe;
    example_process.stderr_behavior = .Pipe;

    var stdout = std.ArrayListUnmanaged(u8){};
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);

    try example_process.spawn();

    try example_process.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);

    const term = try example_process.wait();

    const expected = try readTestFile("c_example.system");
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, stdout.items);
    try std.testing.expectEqual(term, std.process.Child.Term{ .Exited = 0 });
}

test "basic VM" {
    var sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);

    const dtb_file = try std.fs.cwd().openFile(config.dtb ++ "/qemu_virt_aarch64.dtb", .{});
    const dtb_size = (try dtb_file.stat()).size;
    const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    defer allocator.free(blob_bytes);
    // Parse the DTB
    const guest_dtb = try mod.dtb.parse(allocator, blob_bytes);
    defer guest_dtb.deinit(allocator);

    var vmm = ProtectionDomain.create(allocator, "vmm", "vmm.elf", .{});
    sdf.addProtectionDomain(&vmm);

    var vm = try VirtualMachine.create(allocator, "vm", &.{.{ .id = 0 }}, .{});

    var vmm_system = Vmm.init(allocator, &sdf, &vmm, &vm, guest_dtb, dtb_size, .{});

    try vmm_system.connect();

    const expected = try readTestFile("basic_vm.system");
    const output = try sdf.render();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}

test "two VMs" {
    var sdf = SystemDescription.create(allocator, .aarch64, 0x100_000_000);

    const dtb_file = try std.fs.cwd().openFile(config.dtb ++ "/qemu_virt_aarch64.dtb", .{});
    const dtb_size = (try dtb_file.stat()).size;
    const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    defer allocator.free(blob_bytes);
    // Parse the DTB
    const guest_dtb = try mod.dtb.parse(allocator, blob_bytes);
    defer guest_dtb.deinit(allocator);

    var vmm1 = ProtectionDomain.create(allocator, "vmm1", "vmm.elf", .{});
    sdf.addProtectionDomain(&vmm1);
    var vmm2 = ProtectionDomain.create(allocator, "vmm2", "vmm.elf", .{});
    sdf.addProtectionDomain(&vmm2);

    var vm1 = try VirtualMachine.create(allocator, "vm1", &.{.{ .id = 0 }}, .{});
    var vmm_system1 = Vmm.init(allocator, &sdf, &vmm1, &vm1, guest_dtb, dtb_size, .{});
    var vm2 = try VirtualMachine.create(allocator, "vm2", &.{.{ .id = 0 }}, .{});
    var vmm_system2 = Vmm.init(allocator, &sdf, &vmm2, &vm2, guest_dtb, dtb_size, .{});

    try vmm_system1.connect();
    try vmm_system2.connect();

    const expected = try readTestFile("two_vms.system");
    const output = try sdf.render();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}
