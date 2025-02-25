/// Most of our device tree parsing and handling is done by an external
/// dependency, 'dtb.zig'. This file is also called dtb.zig, which is a bit
/// confusing.
/// This module serves to do common higher-level things on the device tree
/// for our device drivers, virtual machines etc.
const std = @import("std");
const dtb = @import("dtb");
const mod_sdf = @import("sdf.zig");

const SystemDescription = mod_sdf.SystemDescription;
const Irq = SystemDescription.Irq;

pub const Node = dtb.Node;
pub const parse = dtb.parse;

pub fn isCompatible(device_compatibles: []const []const u8, compatibles: []const []const u8) bool {
    // Go through the given compatibles and see if they match with anything on the device.
    for (compatibles) |compatible| {
        for (device_compatibles) |device_compatible| {
            if (std.mem.eql(u8, device_compatible, compatible)) {
                return true;
            }
        }
    }

    return false;
}

pub fn memory(d: *dtb.Node) ?*dtb.Node {
    for (d.children) |child| {
        const device_type = child.prop(.DeviceType);
        if (device_type != null) {
            if (std.mem.eql(u8, "memory", device_type.?)) {
                return child;
            }
        }

        if (memory(child)) |memory_node| {
            return memory_node;
        }
    }

    return null;
}

/// Functionality relating the the ARM Generic Interrupt Controller.
// TODO: add functionality for PPI CPU mask handling?
const ArmGicIrqType = enum {
    spi,
    ppi,
    extended_spi,
    extended_ppi,
};

pub const ArmGic = struct {
    const Version = enum { two, three };

    node: *dtb.Node,
    version: Version,
    // While every GIC on an ARM platform that supports virtualisation
    // will have a CPU and vCPU interface interface, they might be via
    // system registers instead of MMIO which is why these fields are optional.
    cpu_paddr: ?u64 = null,
    vcpu_paddr: ?u64 = null,
    vcpu_size: ?u64 = null,

    const compatible = compatible_v2 ++ compatible_v3;
    const compatible_v2 = [_][]const u8{ "arm,gic-v2", "arm,cortex-a15-gic", "arm,gic-400" };
    const compatible_v3 = [_][]const u8{"arm,gic-v3"};

    /// Whether or not the GIC's CPU/vCPU interface is via MMIO
    pub fn hasMmioCpuInterface(gic: ArmGic) bool {
        std.debug.assert((gic.cpu_paddr == null and gic.vcpu_paddr == null and gic.vcpu_size == null) or
            (gic.cpu_paddr != null and gic.vcpu_paddr != null and gic.vcpu_size != null));

        return gic.cpu_paddr != null;
    }

    pub fn nodeIsCompatible(node: *dtb.Node) bool {
        const node_compatible = node.prop(.Compatible).?;
        if (isCompatible(node_compatible, &compatible_v2) or isCompatible(node_compatible, &compatible_v3)) {
            return true;
        } else {
            return false;
        }
    }

    pub fn create(arch: SystemDescription.Arch, node: *dtb.Node) ArmGic {
        // Get the GIC version first.
        const node_compatible = node.prop(.Compatible).?;
        const version = blk: {
            if (isCompatible(node_compatible, &compatible_v2)) {
                break :blk Version.two;
            } else if (isCompatible(node_compatible, &compatible_v3)) {
                break :blk Version.three;
            } else {
                @panic("invalid GIC version");
            }
        };

        const vcpu_dt_index: usize = switch (version) {
            .two => 3,
            .three => 4,
        };
        const cpu_dt_index: usize = switch (version) {
            .two => 1,
            .three => 2,
        };
        const gic_reg = node.prop(.Reg).?;
        const vcpu_paddr = if (vcpu_dt_index < gic_reg.len) regPaddr(arch, node, gic_reg[vcpu_dt_index][0]) else null;
        // Cast should be safe as vCPU should never be larger than u64
        const vcpu_size: ?u64 = if (vcpu_dt_index < gic_reg.len) @intCast(gic_reg[vcpu_dt_index][1]) else null;
        const cpu_paddr = if (cpu_dt_index < gic_reg.len) regPaddr(arch, node, gic_reg[cpu_dt_index][0]) else null;

        return .{
            .node = node,
            .cpu_paddr = cpu_paddr,
            .vcpu_paddr = vcpu_paddr,
            .vcpu_size = vcpu_size,
            .version = version,
        };
    }

    pub fn fromDtb(arch: SystemDescription.Arch, d: *dtb.Node) ?ArmGic {
        // Find the GIC with any compatible string, regardless of version.
        const gic_node = findCompatible(d, &ArmGic.compatible) orelse return null;
        return ArmGic.create(arch, gic_node);
    }
};

pub fn armGicIrqType(irq_type: usize) ArmGicIrqType {
    return switch (irq_type) {
        0x0 => .spi,
        0x1 => .ppi,
        0x2 => .extended_spi,
        0x3 => .extended_ppi,
        else => @panic("unexpected IRQ type"),
    };
}

pub fn armGicIrqNumber(number: u32, irq_type: ArmGicIrqType) u32 {
    return switch (irq_type) {
        .spi => number + 32,
        .ppi => number + 16,
        .extended_spi, .extended_ppi => @panic("unexpected IRQ type"),
    };
}

pub fn armGicTrigger(trigger: usize) Irq.Trigger {
    // Only bits 0-3 of the DT IRQ type are for the trigger
    return switch (trigger & 0b111) {
        0x1 => return .edge,
        0x4 => return .level,
        else => @panic("unexpected trigger value"),
    };
}

pub fn findCompatible(d: *dtb.Node, compatibles: []const []const u8) ?*dtb.Node {
    for (d.children) |child| {
        const device_compatibles = child.prop(.Compatible);
        // It is possible for a node to not have any compatibles
        if (device_compatibles != null) {
            for (compatibles) |compatible| {
                for (device_compatibles.?) |device_compatible| {
                    if (std.mem.eql(u8, device_compatible, compatible)) {
                        return child;
                    }
                }
            }
        }
        if (findCompatible(child, compatibles)) |compatible_child| {
            return compatible_child;
        }
    }

    return null;
}

pub fn findAllCompatible(allocator: std.mem.Allocator, d: *dtb.Node, compatibles: []const []const u8) !std.ArrayList(*dtb.Node) {
    var result = std.ArrayList(*dtb.Node).init(allocator);
    errdefer result.deinit();

    for (d.children) |child| {
        const device_compatibles = child.prop(.Compatible);
        if (device_compatibles != null) {
            for (compatibles) |compatible| {
                for (device_compatibles.?) |device_compatible| {
                    if (std.mem.eql(u8, device_compatible, compatible)) {
                        try result.append(child);
                        break;
                    }
                }
            }
        }

        var child_matches = try findAllCompatible(allocator, child, compatibles);
        defer child_matches.deinit();

        try result.appendSlice(child_matches.items);
    }

    return result;
}

// Given an address from a DTB node's 'reg' property, convert it to a
// mappable MMIO address. This involves traversing any higher-level busses
// to find the CPU visible address rather than some address relative to the
// particular bus the address is on. We also align to the smallest page size;
pub fn regPaddr(arch: SystemDescription.Arch, device: *dtb.Node, paddr: u128) u64 {
    const page_bits = @ctz(arch.defaultPageSize());
    // We have to @intCast here because any mappable address in seL4 must be a
    // 64-bit address or smaller.
    var device_paddr: u64 = @intCast((paddr >> page_bits) << page_bits);
    var parent_node_maybe: ?*dtb.Node = device.parent;
    while (parent_node_maybe) |parent_node| : (parent_node_maybe = parent_node.parent) {
        if (parent_node.prop(.Ranges)) |ranges| {
            if (ranges.len != 0) {
                // TODO: I need to revisit the spec. I am not confident in this behaviour.
                const parent_addr = ranges[0][1];
                const size = ranges[0][2];
                if (paddr + size <= parent_addr) {
                    device_paddr += @intCast(parent_addr);
                }
            }
        }
    }

    return device_paddr;
}
