const std = @import("std");
const libfdt_c = @cImport({
    @cInclude("string.h");
    @cInclude("libfdt_env.h");
    @cInclude("fdt.h");
    @cInclude("libfdt.h");
});

// This file contains wrapper functions around the libfdt C library.

// Panics if libfdt returns an error. See ../libfdt/libfdt.h for more details on these errors.
pub fn libfdt_panic_if_err(errnum: c_int) !void {
    switch (errnum) {
        0 => {
            return;
        },
        -libfdt_c.FDT_ERR_NOTFOUND => {
            @panic("FDT_ERR_NOTFOUND: The requested node or property does not exist");
        },
        -libfdt_c.FDT_ERR_EXISTS => {
            @panic("FDT_ERR_EXISTS: Attempted to create a node or property which already exist");
        },
        -libfdt_c.FDT_ERR_NOSPACE => {
            @panic("FDT_ERR_NOSPACE: Should never get here unless the implementation is broken or you're OOM");
        },
        -libfdt_c.FDT_ERR_BADOFFSET => {
            @panic("FDT_ERR_BADOFFSET: Function was passed a structure block offset which is out-of-bounds, or which points to an unsuitable part of the structure for the operation.");
        },
        -libfdt_c.FDT_ERR_BADPATH => {
            @panic("FDT_ERR_BADPATH: Function was passed a badly formatted path.");
        },
        -libfdt_c.FDT_ERR_BADPHANDLE => {
            @panic("FDT_ERR_BADPHANDLE: Function was passed an invalid phandle.");
        },
        -libfdt_c.FDT_ERR_BADSTATE => {
            @panic("FDT_ERR_BADSTATE: Function was passed an incomplete device tree created by the sequential-write functions, which is not sufficiently complete for the requested operation.");
        },
        -libfdt_c.FDT_ERR_TRUNCATED => {
            @panic("FDT_ERR_TRUNCATED: FDT or a sub-block is improperly terminated");
        },
        -libfdt_c.FDT_ERR_BADMAGIC => {
            @panic("FDT_ERR_BADMAGIC: missing flattened device tree number");
        },
        -libfdt_c.FDT_ERR_BADVERSION => {
            @panic("FDT_ERR_BADVERSION: Given device tree has a version which can't be handled by the requested operation.");
        },
        -libfdt_c.FDT_ERR_BADSTRUCTURE => {
            @panic("FDT_ERR_BADSTRUCTURE: Given device tree has a corrupt structure block or other serious error.");
        },
        -libfdt_c.FDT_ERR_BADLAYOUT => {
            @panic("FDT_ERR_BADLAYOUT: The given device tree has it's sub-blocks in an order that the function can't handle.");
        },
        -libfdt_c.FDT_ERR_INTERNAL => {
            @panic("FDT_ERR_INTERNAL: Bug in libfdt");
        },
        -libfdt_c.FDT_ERR_BADNCELLS => {
            @panic("FDT_ERR_BADNCELLS: Device tree has a #address-cells, #size-cells or similar property with a bad format or value");
        },
        -libfdt_c.FDT_ERR_BADVALUE => {
            @panic("FDT_ERR_BADVALUE: Device tree has a property with an unexpected value.");
        },
        -libfdt_c.FDT_ERR_BADOVERLAY => {
            @panic("FDT_ERR_BADOVERLAY: The device tree overlay, while correctly structured, cannot be applied due to some unexpected or missing value, property or node.");
        },
        -libfdt_c.FDT_ERR_NOPHANDLES => {
            @panic("FDT_ERR_NOPHANDLES: The device tree doesn't have any phandle available anymore without causing an overflow");
        },
        -libfdt_c.FDT_ERR_BADFLAGS => {
            @panic("FDT_ERR_BADFLAGS: The function was passed a flags field that contains invalid flags or an invalid combination of flags.");
        },
        -libfdt_c.FDT_ERR_ALIGNMENT => {
            @panic("FDT_ERR_ALIGNMENT: The device tree base address is not 8-byte aligned.");
        },
        else => {
            std.log.err("libfdt_panic_err: unknown err code {d}", .{errnum});
            @panic("Unknown error code");
        },
    }
}

// This section reimplement some macros in libfdt.h that the Zig C importer can't translate correctly.
pub fn fdt_setprop_string(dtb_blob: []u8, node_off: c_int, name: [*]const u8, str_content: [*]const u8) c_int {
    return libfdt_c.fdt_setprop(dtb_blob.ptr, node_off, name, str_content, @intCast(libfdt_c.strlen(str_content) + 1));
}
