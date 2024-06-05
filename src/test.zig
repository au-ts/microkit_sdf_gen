const std = @import("std");

const SystemDescription = @import("sdf.zig").SystemDescription;
const ProtectionDomain = SystemDescription.ProtectionDomain;
const ProgramImage = ProtectionDomain.ProgramImage;
const MemoryRegion = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Interrupt = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const allocator = std.testing.allocator;
const test_dir = "tests/";

fn readAll(test_path: []const u8) ![]const u8 {
    const test_file = try std.fs.cwd().openFile(test_path, .{});
    const test_file_size = (try test_file.stat()).size;
    return try test_file.reader().readAllAlloc(
        allocator,
        test_file_size,
    );
}

// testing TODOs
// * channels
// * MRs/mappings
// * virtual machine (framebuffer example?)
// * sDDF example

test "basic" {
    var sdf = try SystemDescription.create(allocator, .aarch64);

    const image = ProgramImage.create("hello.elf");
    const pd = ProtectionDomain.create(&sdf, "hello", image);

    sdf.addProtectionDomain(pd);

    const expected = try readAll("src/tests/basic.xml");
    const output = try sdf.toXml();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}

test "PD + MR + mappings + channel" {
    var sdf = try SystemDescription.create(allocator, .aarch64);
    const mr = MemoryRegion.create(&sdf, "test", 0x1000, null, .small);
    sdf.addMemoryRegion(mr);

    const image = ProgramImage.create("hello.elf");
    const pd1 = ProtectionDomain.create(&sdf, "hello-1", image);
    try pd1.addInterrupt(Interrupt.create(33, .level, null));
    pd1.addMap(Map.create(mr, 0x400000000, .{ .read = true }, true, null));
    pd1.addMap(Map.create(mr, 0x600000000, .{ .execute = true }, true, null));
    pd1.addMap(Map.create(mr, 0x800000000, .{ .read = true, .execute = true }, true, null));

    const pd2 = ProtectionDomain.create(&sdf, "hello-2", image);

    sdf.addProtectionDomain(pd1);
    sdf.addProtectionDomain(pd2);

    sdf.addChannel(Channel.create(pd1, pd2));

    const expected = try readAll("src/tests/pd_mr_map_channel.xml");
    const output = try sdf.toXml();
    defer allocator.free(expected);
    defer sdf.destroy();

    try std.testing.expectEqualStrings(expected, output);
}
