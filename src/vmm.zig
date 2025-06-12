const std = @import("std");
const builtin = @import("builtin");
const mod_sdf = @import("sdf.zig");
const dtb = @import("dtb.zig");
const mod_data = @import("data.zig");
const sddf = @import("sddf.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

const fs = std.fs;

const SystemDescription = mod_sdf.SystemDescription;
const Arch = SystemDescription.Arch;
const Mr = SystemDescription.MemoryRegion;
const Pd = SystemDescription.ProtectionDomain;
const Irq = SystemDescription.Irq;
const Map = SystemDescription.Map;
const Vm = SystemDescription.VirtualMachine;

const Self = @This();

allocator: Allocator,
sdf: *SystemDescription,
vmm: *Pd,
guest: *Vm,
guest_dtb: *dtb.Node,
guest_dtb_size: u64,
data: Data,
/// Whether or not to map guest RAM with 1-1 mappings with physical memory
one_to_one_ram: bool,
/// Becomes defined once connect() is called.
guest_ram: Mr = undefined,
gic_vcpu_mr: ?Mr = null,

connected: bool = false,
serialised: bool = false,

const Options = struct {
    one_to_one_ram: bool = false,
};

pub const UIO_NAME_LEN = 32;
pub const LinuxUioRegion = extern struct {
    name: [UIO_NAME_LEN]u8,
    guest_paddr: u64,
    vmm_vaddr: u64,
    size: u64,
    irq: u32,
};

const MAX_IRQS: usize = 32;
const MAX_VCPUS: usize = 32;
const MAX_LINUX_UIO_REGIONS: usize = 16;
const MAX_VIRTIO_MMIO_DEVICES: usize = 32;

const Data = extern struct {
    const VirtioMmioDevice = extern struct {
        pub const Type = enum(u8) {
            net = 1,
            blk = 2,
            console = 3,
            sound = 25,
        };

        type: u8,
        addr: u64,
        size: u32,
        irq: u32,
    };

    const Irq = extern struct {
        id: u8,
        irq: u32,
    };

    const Vcpu = extern struct {
        id: u8,
    };

    magic: [3]u8 = .{ 'v', 'm', 'm' },
    ram: u64,
    ram_size: u64,
    dtb: u64,
    initrd: u64,
    num_irqs: u8,
    irqs: [MAX_IRQS]Data.Irq,
    num_vcpus: u8,
    vcpus: [MAX_VCPUS]Vcpu,
    num_virtio_mmio_devices: u8,
    virtio_mmio_devices: [MAX_VIRTIO_MMIO_DEVICES]VirtioMmioDevice,
    num_linux_uio_regions: u8,
    linux_uios: [MAX_LINUX_UIO_REGIONS]LinuxUioRegion,
};

pub fn init(allocator: Allocator, sdf: *SystemDescription, vmm: *Pd, guest: *Vm, guest_dtb: *dtb.Node, guest_dtb_size: u64, options: Options) Self {
    return .{
        .allocator = allocator,
        .sdf = sdf,
        .vmm = vmm,
        .guest = guest,
        .guest_dtb = guest_dtb,
        .guest_dtb_size = guest_dtb_size,
        .data = std.mem.zeroInit(Data, .{}),
        .one_to_one_ram = options.one_to_one_ram,
    };
}

pub fn deinit(system: *Self) void {
    system.guest_ram.destroy();
    if (system.gic_vcpu_mr) |mr| {
        mr.destroy();
    }
}

fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, s, args) catch @panic("OOM");
}

fn addPassthroughDeviceMapping(system: *Self, name: []const u8, device: *dtb.Node, device_reg: [][2]u128, index: usize) void {
    const device_paddr = dtb.regPaddr(system.sdf.arch, device, device_reg[index][0]);
    const device_size = system.sdf.arch.roundUpToPage(@intCast(device_reg[index][1]));

    const map_perms: Map.Perms = .rw;
    const map_options: Map.Options = .{ .cached = false };

    // Because of multiple devices being on the same page of physical memory occassionally,
    // check if we have already created an MR for this.
    for (system.sdf.mrs.items) |mr| {
        if (mr.paddr) |paddr| {
            if (paddr == device_paddr) {
                for (system.guest.maps.items) |map| {
                    if (map.mr.paddr) |map_paddr| {
                        if (device_paddr == map_paddr) {
                            // Mapping for this MR exists already, nothing to do.
                            return;
                        }
                    }
                }
                // The MR exists but is not mapped in the guest yet, map it in.
                system.guest.addMap(.create(system.allocator, mr, device_paddr, map_perms, map_options));
            }
        }
    }

    var mr_name: []const u8 = undefined;
    var mr_name_allocated = false;
    if (device_reg.len > 1) {
        mr_name = std.fmt.allocPrint(system.allocator, "{s}/{}", .{ name, index }) catch @panic("OOM");
        mr_name_allocated = true;
    } else {
        mr_name = name;
    }
    var device_mr: ?Mr = null;
    for (system.sdf.mrs.items) |mr| {
        if (std.mem.eql(u8, mr_name, mr.name)) {
            device_mr = mr;
        }
    }

    if (device_mr == null) {
        device_mr = Mr.physical(system.allocator, system.sdf, mr_name, device_size, .{
            .paddr = device_paddr,
        });
        system.sdf.addMemoryRegion(device_mr.?);
    }
    system.guest.addMap(.create(system.allocator, device_mr.?, device_paddr, map_perms, map_options));

    if (mr_name_allocated) {
        system.allocator.free(mr_name);
    }
}

pub fn addPassthroughDeviceIrq(system: *Self, interrupt: []u32) !void {
    const irq = try dtb.parseIrq(system.sdf.arch, interrupt);
    const irq_id = try system.vmm.addIrq(irq);
    system.data.irqs[system.data.num_irqs] = .{
        .id = irq_id,
        .irq = irq.irq,
    };
    system.data.num_irqs += 1;
}

const PassthroughOptions = struct {
    /// Indices into the Device Tree node's 'reg' to passthrough
    /// When null, all regions are passed through
    regions: ?[]const u8 = null,
    /// Indices into the Device Tree node's 'interrupts' to passthrough
    /// When null, all interrupts are passed through
    irqs: ?[]const u8 = null,
};

/// Give a virtual machine passthrough access to a device.
/// Depending on the options given, this will add all regions and interrupts
/// associated with the device, a subset of them, or none of them.
pub fn addPassthroughDevice(system: *Self, device: *dtb.Node, options: PassthroughOptions) !void {
    const name = device.name;
    // Find the device, get it's memory regions and add it to the guest. Add its IRQs to the VMM.
    if (device.prop(.Reg)) |device_reg| {
        if (options.regions) |regions| {
            for (regions) |i| {
                if (i >= device_reg.len) {
                    return error.InvalidPassthroughRegions;
                }
                system.addPassthroughDeviceMapping(name, device, device_reg, i);
            }
        } else {
            for (0..device_reg.len) |i| {
                system.addPassthroughDeviceMapping(name, device, device_reg, i);
            }
        }
    } else if (options.regions != null and options.regions.?.len != 0) {
        return error.InvalidPassthroughRegions;
    }

    if (device.prop(.Interrupts)) |interrupts| {
        if (options.irqs) |irqs| {
            for (irqs) |i| {
                if (i >= interrupts.len) {
                    return error.InvalidPassthroughIrqs;
                }
                try system.addPassthroughDeviceIrq(interrupts[i]);
            }
        } else {
            for (0..interrupts.len) |i| {
                try system.addPassthroughDeviceIrq(interrupts[i]);
            }
        }
    } else if (options.irqs != null and options.irqs.?.len != 0) {
        return error.InvalidPassthroughIrqs;
    }
}

fn addVirtioMmioDevice(system: *Self, device: *dtb.Node, t: Data.VirtioMmioDevice.Type) !void {
    const device_reg = device.prop(.Reg) orelse {
        log.err("error adding virtIO device '{s}': missing 'reg' field on device node", .{device.name});
        return error.InvalidVirtioDevice;
    };
    if (device_reg.len != 1) {
        log.err("error adding virtIO device '{s}': invalid number of device regions", .{device.name});
        return error.InvalidVirtioDevice;
    }
    const device_paddr = dtb.regPaddr(system.sdf.arch, device, device_reg[0][0]);
    const device_size = system.sdf.arch.roundUpToPage(@intCast(device_reg[0][1]));

    const interrupts = device.prop(.Interrupts) orelse {
        log.err("error adding virtIO device '{s}': missing 'interrupts' field on device node", .{device.name});
        return error.InvalidVirtioDevice;
    };

    if (interrupts.len != 1) {
        log.err("error adding virtIO device '{s}': expected one entry in 'interrupts' property", .{device.name});
        return error.InvalidVirtioDevice;
    }

    const irq = try dtb.parseIrq(system.sdf.arch, interrupts[0]);
    // TODO: maybe use device resources like everything else? idk
    system.data.virtio_mmio_devices[system.data.num_virtio_mmio_devices] = .{
        .type = @intFromEnum(t),
        .addr = device_paddr,
        .size = @intCast(device_size),
        .irq = irq.irq,
    };
    system.data.num_virtio_mmio_devices += 1;
}

pub fn addVirtioMmioConsole(system: *Self, device: *dtb.Node, serial: *sddf.Serial) !void {
    try serial.addClient(system.vmm);
    try system.addVirtioMmioDevice(device, .console);
}

pub fn addVirtioMmioBlk(system: *Self, device: *dtb.Node, blk: *sddf.Blk, options: sddf.Blk.ClientOptions) !void {
    try blk.addClient(system.vmm, options);
    try system.addVirtioMmioDevice(device, .blk);
}

pub fn addVirtioMmioNet(system: *Self, device: *dtb.Node, net: *sddf.Net, copier: *Pd, options: sddf.Net.ClientOptions) !void {
    try net.addClientWithCopier(system.vmm, copier, options);
    try system.addVirtioMmioDevice(device, .net);
}

pub fn addPassthroughIrq(system: *Self, irq: Irq) !void {
    const irq_id = try system.vmm.addIrq(irq);
    system.data.irqs[system.data.num_irqs] = .{
        .id = irq_id,
        .irq = irq.irq,
    };
    system.data.num_irqs += 1;
}

/// Figure out where to place the DTB based on the guest's RAM and initrd.
/// Our preference is to place it towards the end of RAM.
/// The DTB is always allocated at a page-aligned address.
fn allocateDtbAddress(arch: Arch, dtb_size: u64, ram_start: u64, ram_end: u64, initrd_start: u64, initrd_end: u64) !u64 {
    std.debug.assert(arch.pageAligned(ram_start));
    std.debug.assert(arch.pageAligned(ram_end));

    const initrd_start_page_aligned = arch.roundDownToPage(initrd_start);
    const initrd_end_page_aligned = arch.roundUpToPage(initrd_end);
    const dtb_size_page_aligned = arch.roundUpToPage(dtb_size);
    if (initrd_end_page_aligned + dtb_size_page_aligned <= ram_end) {
        // We can fit it after the DTB
        return initrd_end_page_aligned;
    } else if (initrd_start_page_aligned - dtb_size_page_aligned > ram_start) {
        return initrd_start_page_aligned - dtb_size_page_aligned;
    } else {
        return error.CouldNotAllocateDtb;
    }
}

/// This function parses all UIO regions from the DTB on `connect()` and saves the info into
/// `system.data`. It does NOT map the regions into the guest or VMMs. It is up to the creator
/// of the VMM system to decide which UIO region to map where.
fn parseUios(system: *Self) !void {
    const allocator = system.allocator;

    const uio_nodes = try dtb.findAllCompatible(allocator, system.guest_dtb, &dtb.LinuxUio.compatible);
    defer uio_nodes.deinit();
    if (uio_nodes.items.len >= MAX_LINUX_UIO_REGIONS) {
        log.err("The DTB parser found {d} UIO nodes, but the limit is {d}", .{ uio_nodes.items.len, MAX_LINUX_UIO_REGIONS });
        return error.InvalidUio;
    }

    for (uio_nodes.items, 0..) |node, i| {
        const compatibles: [][]const u8 = node.prop(.Compatible).?;

        if (compatibles.len != 2) {
            // NULL must be used as the delimiter as the DTB parser assumes NULL.
            log.err("Compatibile string {s} isn't in the expected format of 'generic-uio\\0<name>'.", .{node.prop(.Compatible).?});
            return error.InvalidUio;
        }
        const node_name = compatibles[1];

        if (node_name.len > UIO_NAME_LEN - 1) {
            log.err("Encountered UIO node '{s}', with name of length {d}, greater than limit of {d}.", .{ node_name, node_name.len, UIO_NAME_LEN - 1 });
            return error.InvalidUio;
        }
        if (system.findUio(node_name) != null) {
            log.err("Encountered UIO node with duplicate name: {s}", .{node_name});
            return error.InvalidUio;
        }

        const uio_node = try dtb.LinuxUio.create(allocator, node, system.sdf.arch);

        system.data.linux_uios[i] = .{
            .name = undefined,
            .size = uio_node.size,
            .guest_paddr = uio_node.guest_paddr,
            .irq = uio_node.irq orelse 0,
            // We don't map the UIO regions into the VMM by default as sometimes
            // they are intentionally "fake" for the guest to generate
            // faults as an event signalling mechanism. It is up to whoever using
            // the VMM system to map in.
            .vmm_vaddr = 0,
        };
        @memset(&system.data.linux_uios[i].name, 0);
        const name_to_copy_len = @min(node_name.len, UIO_NAME_LEN);
        const name_to_copy = node_name[0..name_to_copy_len];
        std.mem.copyForwards(u8, &system.data.linux_uios[i].name, name_to_copy);

        system.data.num_linux_uio_regions += 1;
    }
}

pub fn findUio(system: *Self, target_name: []const u8) ?*LinuxUioRegion {
    for (0..system.data.num_linux_uio_regions) |i| {
        if (std.mem.eql(u8, target_name, system.data.linux_uios[i].name[0..target_name.len])) {
            return &system.data.linux_uios[i];
        }
    }

    return null;
}

pub fn connect(system: *Self) !void {
    const allocator = system.allocator;
    var sdf = system.sdf;
    const arch = sdf.arch;
    const vmm = system.vmm;
    const guest = system.guest;
    try vmm.setVirtualMachine(guest);

    if (sdf.arch.isArm()) {
        const gic = dtb.ArmGic.fromDtb(sdf.arch, system.guest_dtb) orelse {
            log.err("error connecting VMM '{s}' system: could not find GIC interrupt controller DTB node", .{vmm.name});
            return error.MissinGicNode;
        };
        if (gic.hasMmioCpuInterface()) {
            const gic_vcpu_mr_name = fmt(allocator, "{s}/vcpu", .{gic.node.name});
            defer allocator.free(gic_vcpu_mr_name);
            // On ARM, map in the GIC vCPU device as the GIC CPU device in the guest's memory.
            var gic_vcpu_mr: ?Mr = null;
            for (sdf.mrs.items) |mr| {
                if (std.mem.eql(u8, gic_vcpu_mr_name, mr.name)) {
                    gic_vcpu_mr = mr;
                }
            }
            if (gic_vcpu_mr == null) {
                gic_vcpu_mr = Mr.physical(allocator, sdf, gic_vcpu_mr_name, gic.vcpu_size.?, .{ .paddr = gic.vcpu_paddr.? });
                system.gic_vcpu_mr = gic_vcpu_mr;
                sdf.addMemoryRegion(gic_vcpu_mr.?);
            }
            const gic_guest_map = Map.create(allocator, gic_vcpu_mr.?, gic.cpu_paddr.?, .rw, .{ .cached = false });
            guest.addMap(gic_guest_map);
        }
    }

    const memory_node = dtb.memory(system.guest_dtb) orelse {
        log.err("error connecting VMM '{s}' system: could not find 'memory' DTB node", .{vmm.name});
        return error.MissingMemoryNode;
    };
    const memory_reg = memory_node.prop(.Reg) orelse {
        log.err("error connecting VMM '{s}' system: 'memory' node does not have 'reg' field", .{vmm.name});
        return error.InvalidMemoryNode;
    };
    if (memory_reg.len != 1) {
        log.err("error connecting VMM '{s}' system: expected 1 main memory region, found {}", .{ vmm.name, memory_reg.len });
        return error.InvalidMemoryNode;
    }

    const memory_paddr: u64 = @intCast(memory_reg[0][0]);
    const guest_mr_name = std.fmt.allocPrint(allocator, "guest_ram_{s}", .{guest.name}) catch @panic("OOM");
    defer allocator.free(guest_mr_name);
    const guest_ram_size: u64 = @intCast(memory_reg[0][1]);

    const guest_ram_mr = blk: {
        if (system.one_to_one_ram) {
            break :blk Mr.physical(allocator, sdf, guest_mr_name, guest_ram_size, .{ .paddr = memory_paddr });
        } else {
            break :blk Mr.create(allocator, guest_mr_name, guest_ram_size, .{});
        }
    };
    sdf.addMemoryRegion(guest_ram_mr);
    vmm.addMap(.create(allocator, guest_ram_mr, memory_paddr, .rw, .{}));
    guest.addMap(.create(allocator, guest_ram_mr, memory_paddr, .rwx, .{}));

    system.guest_ram = guest_ram_mr;

    for (system.guest.vcpus) |vcpu| {
        system.data.vcpus[system.data.num_vcpus] = .{
            .id = vcpu.id,
        };
        system.data.num_vcpus += 1;
    }

    const initrd_start = blk: {
        if (system.guest_dtb.propAt(&.{"chosen"}, .LinuxInitrdStart)) |addr| {
            break :blk addr;
        } else {
            return error.MissingInitrd;
        }
    };
    const initrd_end = blk: {
        if (system.guest_dtb.propAt(&.{"chosen"}, .LinuxInitrdEnd)) |addr| {
            break :blk addr;
        } else {
            return error.MissingInitrd;
        }
    };

    if (initrd_end <= initrd_start) {
        log.err("invalid initrd region for VMM '{s}': end address 0x{x} is less than start address 0x{x}", .{ vmm.name, initrd_end, initrd_start });
        return error.InvalidInitrd;
    }

    if (initrd_end > memory_paddr + guest_ram_size or initrd_start < memory_paddr) {
        log.err("invalid initrd region for VMM '{s}': initrd at [0x{x}..0x{x}) is not within guest main memory [0x{x}..0x{x})", .{ vmm.name, initrd_start, initrd_end, memory_paddr, memory_paddr + guest_ram_size });
        return error.InvalidInitrd;
    }

    try parseUios(system);

    system.data.ram = memory_paddr;
    system.data.ram_size = guest_ram_size;
    system.data.dtb = try allocateDtbAddress(arch, system.guest_dtb_size, system.data.ram, system.data.ram + system.data.ram_size, initrd_start, initrd_end);
    system.data.initrd = initrd_start;

    system.connected = true;
}

pub fn serialiseConfig(system: *Self, prefix: []const u8) !void {
    if (!system.connected) return error.NotConnected;

    const allocator = system.allocator;
    const config_name = fmt(allocator, "vmm_{s}", .{system.vmm.name});

    try mod_data.serialize(allocator, system.data, prefix, config_name);

    system.serialised = true;
}
