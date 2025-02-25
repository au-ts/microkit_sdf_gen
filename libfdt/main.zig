const std = @import("std");

const libfdt_c = @cImport({
    @cInclude("libfdt_env.h");
    @cInclude("fdt.h");
    @cInclude("libfdt.h");
});

pub fn main() !void {
    std.debug.print("fdt magic is: {d}\n", .{libfdt_c.FDT_MAGIC});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("../sddf/dts/odroidc4.dtb", .{});
    defer file.close();

    const blob = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(blob);

    var err = libfdt_c.fdt_check_header(blob.ptr);
    if (err != 0) {
        std.log.err("err {d}", .{err});
        @panic("check header fail");
    }

    std.debug.print("fdt header ok\n", .{});

    const num_mem_rsv = libfdt_c.fdt_num_mem_rsv(blob.ptr);
    std.debug.print("num reserved mem regions {d}\n", .{num_mem_rsv});
    var i: c_int = 0;
    while (i < num_mem_rsv) {
        var rsv_paddr: u64 = 0;
        var rsv_sz: u64 = 0;

        err = libfdt_c.fdt_get_mem_rsv(blob.ptr, i, &rsv_paddr, &rsv_sz);
        if (err != 0) {
            std.log.err("err {d}", .{err});
            @panic("get reserved mem fail");
        }

        std.debug.print("reserved mem @ {x} size {x}\n", .{rsv_paddr, rsv_sz});

        i += 1;
    }
}
