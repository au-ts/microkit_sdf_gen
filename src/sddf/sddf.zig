const std = @import("std");
const mod_sdf = @import("../sdf.zig");
const dtb = @import("../dtb.zig");
const data = @import("../data.zig");
const log = @import("../log.zig");

pub const I2c = @import("i2c.zig").I2c;
pub const Blk = @import("blk.zig").Blk;
pub const Timer = @import("timer.zig").Timer;
pub const Net = @import("net.zig").Net;
pub const Lwip = @import("net.zig").Lwip;
pub const Gpu = @import("gpu.zig").Gpu;
pub const Pci = @import("pci.zig").Pci;
pub const Serial = @import("serial.zig").Serial;

const fs = std.fs;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Pd = SystemDescription.ProtectionDomain;
const Irq = SystemDescription.Irq;
const Channel = SystemDescription.Channel;
const SetVar = SystemDescription.SetVar;

const ConfigResources = data.Resources;

// TODO: apply this more widely
pub const DeviceTreeIndex = u8;
///
/// Expected sDDF repository layout:
///     -- network/
///     -- serial/
///     -- drivers/
///         -- network/
///         -- serial/
///
/// Essentially there should be a top-level directory for a
/// device class and aa directory for each device class inside
/// 'drivers/'.
///
var drivers: std.array_list.Managed(Config.Driver) = undefined;
var classes: std.array_list.Managed(Config.DeviceClass) = undefined;

const CONFIG_FILENAME = "config.json";

/// Whether or not we have probed sDDF
// TODO: should probably just happen upon `init` of sDDF, then
// we pass around sddf everywhere?
var probed = false;

pub fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, s, args) catch @panic("OOM");
}

/// Assumes probe() has been called
pub fn compatibleDrivers(allocator: Allocator) ![]const []const u8 {
    // We already know how many drivers exist as well as all their compatible
    // strings, so we know exactly how large the array needs to be.
    var num_compatible: usize = 0;
    for (drivers.items) |driver| {
        num_compatible += driver.compatible.len;
    }
    var array = try std.array_list.Managed([]const u8).initCapacity(allocator, num_compatible);
    for (drivers.items) |driver| {
        for (driver.compatible) |compatible| {
            array.appendAssumeCapacity(compatible);
        }
    }

    return try array.toOwnedSlice();
}

// pub fn wasmProbe(allocator: Allocator, driverConfigs: anytype, classConfigs: anytype) !void {
//     drivers = std.array_list.Managed(Config.Driver).init(allocator);
//     classes = std.array_list.Managed(Config.DeviceClass).initCapacity(allocator, @typeInfo(Config.DeviceClass).Enum.fields.len);

//     var i: usize = 0;
//     while (i < driverConfigs.items.len) : (i += 1) {
//         const config = driverConfigs.items[i].object;
//         const json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, config.get("content").?.string, .{});
//         try drivers.append(Config.Driver.fromJson(json, config.get("class").?.string));
//     }
//     // for (driverConfigs) |config| {
//     //     const json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, config.get("content").?.content, .{});
//     //     try drivers.append(Config.Driver.fromJson(json, config.get("class").?.name));
//     // }

//     i = 0;
//     while (i < classConfigs.items.len) : (i += 1) {
//         const config = classConfigs.items[i].object;
//         const json = try std.json.parseFromSliceLeaky(Config.DeviceClass.Json, allocator, config.get("content").?.string, .{});
//         try classes.appendAssumeCapacity(Config.DeviceClass.fromJson(json, config.get("class").?.string));
//     }
//     // for (classConfigs) |config| {
//     //     const json = try std.json.parseFromSliceLeaky(Config.DeviceClass.Json, allocator, config.get("content").?.content, .{});
//     //     try classes.appendAssumeCapacity(Config.DeviceClass.fromJson(json, config.get("class").?.name));
//     // }
//     probed = true;
// }

/// As part of the initilisation, we want to find all the JSON configuration
/// files, parse them, and built up a data structure for us to then search
/// through whenever we want to create a driver to the system description.
pub fn probe(allocator: Allocator, path: []const u8) !void {
    drivers = std.array_list.Managed(Config.Driver).init(allocator);

    log.debug("starting sDDF probe", .{});
    log.debug("opening sDDF root dir '{s}'", .{path});
    var sddf = fs.cwd().openDir(path, .{}) catch |e| {
        log.err("failed to open sDDF directory '{s}': {}", .{ path, e });
        return e;
    };
    defer sddf.close();

    const device_classes = comptime std.meta.fields(Config.Driver.Class);
    inline for (device_classes) |device_class| {
        var checked_compatibles = std.array_list.Managed([]const u8).init(allocator);
        // Search for all the drivers. For each device class we need
        // to iterate through each directory and find the config file
        for (@as(Config.Driver.Class, @enumFromInt(device_class.value)).dirs()) |dir| {
            const driver_dir = fmt(allocator, "drivers/{s}", .{dir});
            var device_class_dir = sddf.openDir(driver_dir, .{ .iterate = true }) catch |e| {
                log.err("failed to open sDDF driver directory '{s}': {}", .{ driver_dir, e });
                return e;
            };
            defer device_class_dir.close();
            var iter = device_class_dir.iterate();
            while (iter.next() catch |e| {
                log.err("failed to iterate sDDF driver directory '{s}': {}", .{ driver_dir, e });
                return e;
            }) |entry| {
                if (entry.kind != .directory) {
                    continue;
                }
                // Under this directory, we should find the configuration file
                const config_path = fmt(allocator, "{s}/config.json", .{entry.name});
                defer allocator.free(config_path);
                // Attempt to open the configuration file. It is realistic to not
                // have every driver to have a configuration file associated with
                // it, especially during the development of sDDF.
                const config_file = device_class_dir.openFile(config_path, .{}) catch |e| {
                    switch (e) {
                        error.FileNotFound => {
                            continue;
                        },
                        else => {
                            log.err("failed to open driver configuration file '{s}': {}\n", .{ config_path, e });
                            return e;
                        },
                    }
                };
                defer config_file.close();
                log.debug("file: {s}/{s}", .{ dir, config_path });
                const config_file_stat = config_file.stat() catch |e| {
                    log.err("failed to stat driver config file: {s}: {}", .{ config_path, e });
                    return e;
                };
                const config_bytes = try config_file.deprecatedReader().readAllAlloc(allocator, @intCast(config_file_stat.size));
                // TODO; free config? we'd have to dupe the json data when populating our data structures
                assert(config_bytes.len == config_file_stat.size);
                // TODO: should probably free the memory at some point
                // We are using an ArenaAllocator so calling parseFromSliceLeaky instead of parseFromSlice
                // is recommended.
                const json = std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, config_bytes, .{}) catch |e| {
                    log.err("failed to parse JSON configuration '{s}/{s}/{s}' with error '{}'", .{ path, driver_dir, config_path, e });
                    return error.JsonParse;
                };

                // This should never fail since device_class.name must be valid since we are looping
                // based on the valid device classes.
                const config = Config.Driver.fromJson(json, device_class.name, fmt(allocator, "{s}/{s}", .{ driver_dir, entry.name })) catch unreachable;

                // Check IRQ resources are valid
                var checked_irqs = std.array_list.Managed(DeviceTreeIndex).init(allocator);
                defer checked_irqs.deinit();
                for (config.resources.irqs) |irq| {
                    log.debug("irq: {any}", .{irq.irq_type.?});
                    if (irq.irq_type.? == .legacy) {
                        for (checked_irqs.items) |checked_dt_index| {
                            if (irq.dt_index.? == checked_dt_index) {
                                log.err("duplicate irq dt_index value '{}' for driver '{s}'", .{ irq.dt_index.?, driver_dir });
                                return error.InvalidConfig;
                            }
                        }

                        try checked_irqs.append(irq.dt_index.?);
                    }
                }

                log.debug("regions", .{});
                // Check region resources are valid
                var checked_regions = std.array_list.Managed(Config.Region).init(allocator);
                defer checked_regions.deinit();
                for (config.resources.regions) |region| {
                    for (checked_regions.items) |checked_region| {
                        if (std.mem.eql(u8, region.name, checked_region.name)) {
                            log.err("duplicate region name '{s}' for driver '{s}'", .{ region.name, driver_dir });
                            return error.InvalidConfig;
                        }
                        if (region.dt_index != null and checked_region.dt_index != null) {
                            if (region.dt_index.? == checked_region.dt_index.?) {
                                log.err("duplicate region dt_index value '{}' for driver '{s}'", .{ region.dt_index.?, driver_dir });
                                return error.InvalidConfig;
                            }
                        }
                    }
                    try checked_regions.append(region);
                }

                log.debug("compatible", .{});
                // Check there are no duplicate compatible strings for the same device class
                for (config.compatible) |compatible| {
                    for (checked_compatibles.items) |checked_compatible| {
                        if (std.mem.eql(u8, checked_compatible, compatible)) {
                            log.err("duplicate compatible string '{s}' for driver '{s}'", .{ compatible, driver_dir });
                            return error.InvalidConfig;
                        }
                    }
                    try checked_compatibles.append(compatible);
                }

                log.debug("check PCI bars", .{});
                // Check PCI BARs are valid
                var checked_bars = std.array_list.Managed(Config.PciBar).init(allocator);
                defer checked_bars.deinit();
                if (config.resources.pci_bars) |pci_bars| {
                    for (pci_bars) |pci_bar| {
                        for (checked_bars.items) |checked_bar| {
                            if (checked_bar.bar_id == pci_bar.bar_id) {
                                log.err("duplicate bar_id '{}' for driver '{s}'", .{ pci_bar.bar_id, driver_dir });
                                return error.InvalidConfig;
                            }
                        }
                    }
                }

                log.debug("hello", .{});

                try drivers.append(config);
            }
        }
    }

    // Probing finished
    probed = true;
}

pub const Config = struct {

    const Region = struct {
        /// Name of the region
        name: []const u8,
        /// Permissions to the region of memory once mapped in
        perms: ?[]const u8 = null,
        setvar_vaddr: ?[]const u8 = null,
        size: ?usize = null,
        /// Since we're often talking about device memory, default to false
        cached: ?bool = false,
        // Index into 'reg' property of the device tree
        dt_index: ?DeviceTreeIndex = null,
    };

    /// The actual IRQ number that gets registered with seL4
    /// is something we can determine from the device tree.
    const Irq = struct {
        channel_id: ?u8 = null,
        /// Index into the 'interrupts' property of the Device Tree
        dt_index: ?DeviceTreeIndex = null,
        vector: ?u64 = null,
        pin: ?u64 = null,
        irq_type: ?IrqType = .legacy,
    };

    // .legacy for ARM and RISCV, and others for x86 atm
    pub const IrqType = enum(u8) { legacy, ioapic, msi, msix };

    // Struct used in config.json, and slightly different from generated header
    pub const PciBar = struct {
        region_idx: u8,
        bar_id: u8,
        mem_mapped: ?bool = true,
        mem_64b: ?bool = false,
    };

    /// In the case of drivers there is some extra information we want
    /// to store that is not specified in the JSON configuration.
    /// For example, the device class that the driver belongs to.
    pub const Driver = struct {
        dir: []const u8,
        class: Class,
        compatible: []const []const u8,
        resources: Resources,

        pub const Resources = struct {
            regions: []const Region,
            irqs: []const Config.Irq,
            pci_bars: ?[]const PciBar = null,
        };

        pub const Json = struct {
            compatible: []const []const u8,
            resources: Resources,
        };

        pub fn fromJson(json: Json, class_str: []const u8, dir: []const u8) !Driver {
            const class = Class.fromStr(class_str);
            if (class == null) {
                return error.InvalidClass;
            }
            return .{
                .dir = dir,
                .class = class.?,
                .compatible = json.compatible,
                .resources = json.resources,
            };
        }

        /// These are the sDDF device classes that we expect to exist in the
        /// repository and will be searched through.
        /// You could instead have something in the repisitory to list the
        /// device classes or organise the repository differently, but I do
        /// not see the need for that kind of complexity at this time.
        pub const Class = enum {
            network,
            serial,
            timer,
            blk,
            i2c,
            gpu,

            pub fn fromStr(str: []const u8) ?Class {
                inline for (std.meta.fields(Class)) |field| {
                    if (std.mem.eql(u8, str, field.name)) {
                        return @enumFromInt(field.value);
                    }
                }

                return null;
            }

            pub fn dirs(comptime self: Class) []const []const u8 {
                return switch (self) {
                    .network => &.{"network", "network/virtio"},
                    .serial => &.{"serial"},
                    .timer => &.{"timer"},
                    .blk => &.{ "blk", "blk/mmc", "blk/virtio" },
                    .i2c => &.{"i2c"},
                    .gpu => &.{"gpu"},
                };
            }
        };
    };
};

pub const SystemError = error{
    NotConnected,
    InvalidClient,
    DuplicateClient,
};

/// Assumes probe() has been called
fn findDriver(compatibles: []const []const u8, class: Config.Driver.Class) ?Config.Driver {
    assert(probed);
    for (drivers.items) |driver| {
        // This is yet another point of weirdness with device trees. It is often
        // the case that there are multiple compatible strings for a device and
        // accompying driver. So we get the user to provide a list of compatible
        // strings, and we check for a match with any of the compatible strings
        // of a driver.
        for (compatibles) |compatible| {
            for (driver.compatible) |driver_compatible| {
                if (std.mem.eql(u8, driver_compatible, compatible) and driver.class == class) {
                    // We have found a compatible driver
                    return driver;
                }
            }
        }
    }

    return null;
}

/// Given the DTB node for the device and the SDF program image, we can figure
/// all the resources that need to be added to the system description.
pub fn createDriver(sdf: *SystemDescription, pd: *Pd, device: ?*dtb.Node, preferred_compatible: ?[]const u8, class: Config.Driver.Class, device_res: *ConfigResources.Device) !void {

    log.debug("gdnhsgdag", .{});
    if (!probed) return error.CalledBeforeProbe;

    // // TODO: the tooling is quite DTB based, we need to revisit this for x86-64 support,
    // // this is a bit of a hack right now.
    // if (SystemDescription.Arch.isX86(sdf.arch)) {
    //     // No DTB on x86.
    //     return;
    // }
    if (device == null and preferred_compatible == null) {
        log.err("Either device or compatible needs to be provided", .{});
        return error.UnknownDevice;
    }

    const compatible = if (preferred_compatible) |c| &[_][]const u8{ c } else blk: {
        // First thing to do is find the driver configuration for the device given.
        // The way we do that is by searching for the compatible string described in the DTB node.
        const dt_compatible = device.?.prop(.Compatible).?;

        log.debug("Creating driver for device: '{s}'", .{device.?.name});
        log.debug("Compatible with:", .{});
        for (dt_compatible) |c| {
            log.debug("     '{s}'", .{c});
        }
        break :blk dt_compatible;
    };
    log.debug("compatible: {any}", .{ compatible });
    // Get the driver based on the compatible string are given, assuming we can
    // find it.
    const driver = if (findDriver(compatible, class)) |d| d else {
        log.err("Cannot find driver matching '{s}' for class '{s}'", .{ device.?.name, @tagName(class) });
        return error.UnknownDevice;
    };
    log.debug("Found compatible driver '{s}'", .{driver.dir});

    // If a status property does exist, we should check that it is 'okay'
    if (device) |d| {
        if (d.prop(.Status)) |status| {
            log.debug("what?", .{});
            if (status != .Okay) {
                log.err("Device '{s}' has invalid status: '{f}'", .{ d.name, status });
                return error.DeviceStatusInvalid;
            }
        }
    }

    log.debug("adding regions", .{});
    for (driver.resources.regions, 0..) |region_resource, region_idx| {
        // TODO: all this error checking should be done when we parse config.json
        if (region_resource.dt_index == null and region_resource.size == null) {
            log.err("driver '{s}' has region resource '{s}' which specifies neither dt_index nor size: one or both must be specified", .{ driver.dir, region_resource.name });
            return error.InvalidConfig;
        }

        if (region_resource.dt_index != null and region_resource.cached != null and region_resource.cached.? == true) {
            log.err("driver '{s}' has region resource '{s}' which tries to map MMIO region as cached", .{ driver.dir, region_resource.name });
            return error.InvalidConfig;
        }

        const dev_name = if (device) |d| d.name else pd.name;
        const mr_name = fmt(sdf.allocator, "{s}/{s}/{s}", .{ dev_name, driver.dir, region_resource.name });

        var mr: ?Mr = null;
        var device_reg_offset: u64 = 0;
        if (region_resource.dt_index != null) {
            if (device) |dev| {
                const dt_reg = dev.prop(.Reg).?;
                assert(region_resource.dt_index.? < dt_reg.len);

                const dt_reg_entry = dt_reg[region_resource.dt_index.?];
                const dt_reg_paddr = dt_reg_entry[0];
                const dt_reg_size = sdf.arch.roundUpToPage(@intCast(dt_reg_entry[1]));

                if (region_resource.size != null and dt_reg_size < region_resource.size.?) {
                    log.err("device '{s}' has config region size for dt_index '{?}' that is too small (0x{x} bytes)", .{ dev.name, region_resource.dt_index, dt_reg_size });
                    return error.InvalidConfig;
                }

                if (region_resource.size != null and region_resource.size.? & (sdf.arch.defaultPageSize() - 1) != 0) {
                    log.err("device '{s}' has config region size not aligned to page size for dt_index '{?}'", .{ dev.name, region_resource.dt_index });
                    return error.InvalidConfig;
                }

                if (!sdf.arch.pageAligned(dt_reg_size)) {
                    log.err("device '{s}' has DTB region size not aligned to page size for dt_index '{?}'", .{ dev.name, region_resource.dt_index });
                    return error.InvalidConfig;
                }

                const mr_size = if (region_resource.size != null) region_resource.size.? else dt_reg_size;

                const device_paddr = dtb.regPaddr(sdf.arch, dev, @intCast(dt_reg_paddr));
                device_reg_offset = @intCast(dt_reg_paddr % sdf.arch.defaultPageSize());

                // If we are dealing with a device that shares the same page of memory as another
                // device, we need to check whether an MR has already been created and use that
                // for our mapping instead.
                for (sdf.mrs.items) |existing_mr| {
                    if (existing_mr.paddr) |paddr| {
                        if (paddr == device_paddr) {
                            mr = existing_mr;
                        }
                    }
                }
                if (mr == null) {
                    mr = Mr.physical(sdf.allocator, sdf, mr_name, mr_size, .{ .paddr = device_paddr });
                    sdf.addMemoryRegion(mr.?);
                }

            }
        } else {
            var is_pci_bar : bool = false;
            for (driver.resources.pci_bars.?) |pci_bar| {
                if (pci_bar.region_idx == region_idx) {
                    is_pci_bar = true;
                    break;
                }
            }
            if (is_pci_bar) {
                // Skip the region and leave the job to composePciConfig()
                device_res.num_regions += 1;
                continue;
            }

            const mr_size = region_resource.size.?;
            mr = Mr.physical(sdf.allocator, sdf, mr_name, mr_size, .{});
            sdf.addMemoryRegion(mr.?);
        }

        const perms = blk: {
            if (region_resource.perms) |perms| {
                break :blk Map.Perms.fromString(perms) catch |e| {
                    log.err("failed to create driver '{s}', invalid perms '{s}': {any}", .{ device.?.name, perms, e });
                    return e;
                };
            } else {
                break :blk Map.Perms.rw;
            }
        };
        const map = Map.create(mr.?, pd.getMapVaddr(&mr.?), perms, .{
            .cached = region_resource.cached,
            .setvar_vaddr = region_resource.setvar_vaddr,
        });
        pd.addMap(map);
        device_res.regions[device_res.num_regions] = .{
            .region = .{
                // The driver that is consuming the device region wants to know about the
                // region that is specifeid in the DTB node, rather than the start of the region that
                // is mapped. While uncommon, sometimes the device region is not page-aligned unlike
                // the mapping.
                .vaddr = map.vaddr + device_reg_offset,
                .size = map.mr.size,
            },
            .io_addr = map.mr.paddr.?,
        };
        device_res.num_regions += 1;
    }

    // MSI/MSI-X not supported on ARM in seL4
    if (device != null) {
        // For all driver IRQs, find the corresponding entry in the device tree and
        // process it for the SDF.
        const maybe_dt_irqs = device.?.prop(.Interrupts);
        if (driver.resources.irqs.len != 0 and maybe_dt_irqs == null) {
            log.err("expected interrupts field for node '{s}' when creating driver '{s}'", .{ device.?.name, driver.dir });
            return error.InvalidDeviceTreeNode;
        }

        for (driver.resources.irqs) |driver_irq| {
            const dt_irqs = maybe_dt_irqs.?;
            if (driver_irq.dt_index.? >= dt_irqs.len) {
                log.err("invalid device tree index '{}' when creating driver '{s}'", .{ driver_irq.dt_index.?, driver.dir });
                return error.InvalidDeviceTreeIndex;
            }
            const dt_irq = dt_irqs[driver_irq.dt_index.?];

            const irq = try dtb.parseIrq(sdf.arch, dt_irq);
            const irq_id = try pd.addIrq(Irq.create(
                irq.number().?,
                .{
                    .id = driver_irq.channel_id,
                    .trigger = irq.trigger(),
                }
            ));

            device_res.irqs[device_res.num_irqs] = .{
                .id = irq_id,
            };
            device_res.num_irqs += 1;
        }
    }
}

pub fn composePciConfig(pci: *Pci, pd: *Pd, compatible: []const u8, class: Config.Driver.Class, device_res: *ConfigResources.Device, dev: Pci.DeviceOptions) !ConfigResources.Pci.ConfigRequest {

    // Get the driver based on the compatible string are given, assuming we can
    // find it.
    const driver = if (findDriver(&[_][]const u8{ compatible }, class)) |d| d else {
        log.err("Cannot find driver matching '{s}' for class '{s}'", .{ compatible, @tagName(class) });
        return error.UnknownDevice;
    };
    log.debug("Found compatible driver '{s}'", .{driver.dir});

    var is_ioapic_enabled = true;
    // TODO: check if MSI interrupts are contiguous

    var requested_irqs = [_]ConfigResources.Pci.PciIrq{std.mem.zeroInit(ConfigResources.Pci.PciIrq, .{})} ** ConfigResources.Pci.MAX_PCI_IRQS;
    var requested_num_irqs : u8 = 0;
    for (driver.resources.irqs) |irq| {
        const irq_id = blk: {
            switch (irq.irq_type.?) {
                .ioapic => {
                    if (!is_ioapic_enabled) {
                        log.err("I/O APIC cannot work with MSI/MSI-X", .{});
                        return error.InvalidPciConfig;
                    }

                    requested_irqs[requested_num_irqs] = .{
                        .pin = irq.pin.?,
                        .vector = irq.vector.?,
                        .kind = .ioapic
                    };

                    break :blk try pd.addIrq(Irq.createIoapic(
                        irq.pin.?,
                        irq.vector.?,
                        .{}
                    ) catch @panic("Could not create I/O APIC interrupt"));
                },
                .msi, => {
                    is_ioapic_enabled = false;

                    // TODO: figure out what's the use of the handle argument
                    if (irq.vector) |vector| {

                        requested_irqs[requested_num_irqs] = (.{
                            .pin = 0,
                            .vector = irq.vector.?,
                            .kind = .msi,
                        });

                        break :blk try pd.addIrq(try Irq.createMsi(
                            dev.pci_bus,
                            dev.pci_dev,
                            dev.pci_func,
                            vector,
                            0,
                            .{}
                        ));

                    } else {
                        log.err("'vector' is expected for MSI interrupts", .{});
                        return error.InvalidClientConfig;
                    }
                },
                .msix => {
                    is_ioapic_enabled = false;

                    // TODO: figure out what's the use of the handle argument
                    if (irq.vector) |vector| {

                        requested_irqs[requested_num_irqs] = (.{
                            .pin = 0,
                            .vector = irq.vector.?,
                            .kind = .msix,
                        });

                        // Allocate 0x9000 for a MSI-X capability
                        const msix_region_name = fmt(pci.allocator, "msix_bar_{}", .{ pci.device_res.num_regions });
                        pci.addMemoryRegion(pci.mmio_paddr_top - 0x9000, 0x9000, msix_region_name);
                        pci.mmio_paddr_top -= 0x9000;

                        break :blk try pd.addIrq(try Irq.createMsi(
                            dev.pci_bus,
                            dev.pci_dev,
                            dev.pci_func,
                            vector,
                            0,
                            .{}
                        ));
                    } else {
                        log.err("'vector' is expected for MSI-X interrupts", .{});
                        return error.InvalidClientConfig;
                    }
                },
                else => {
                    log.err("Legacy interrupts are not supported for PCI devices\n", .{});
                    return error.InvalidPciConfig;
                }
            }
        };
        device_res.irqs[device_res.num_irqs] = .{
            .id = irq_id,
        };
        device_res.num_irqs += 1;
        log.debug("num_irqs: {}", .{ device_res.num_irqs });
        requested_num_irqs += 1;
    }

    var requested_bars = [_]ConfigResources.Pci.PciBar{std.mem.zeroInit(ConfigResources.Pci.PciBar, .{})} ** ConfigResources.Pci.MAX_PCI_BARS;
    for (driver.resources.pci_bars.?) |pci_bar| {

        const region_resource = driver.resources.regions[pci_bar.region_idx];
        const mr_size = if (region_resource.size != null) region_resource.size.? else {
            log.err("region '{}' has unknown region size'", .{ pci_bar.region_idx });
            return error.InvalidConfig;
        };
        const mr_name = fmt(pci.allocator, "{s}/{s}/{s}", .{ pd.name, driver.dir, region_resource.name });

        // Some devices require base address 0x10000-byte aligned
        const alignment : u64 = 0x10000;
        const paddr = (pci.mmio_paddr_top - mr_size) & ~(alignment - 1);
        const mr = Mr.physical(pci.allocator, pci.sdf, mr_name, mr_size, .{ .paddr = paddr });
        pci.mmio_paddr_top = paddr;
        pci.sdf.addMemoryRegion(mr);
        const perms = blk: {
            if (region_resource.perms) |perms| {
                break :blk Map.Perms.fromString(perms) catch |e| {
                    log.err("failed to create driver '{s}', invalid perms '{s}': {any}", .{ pd.name, perms, e });
                    return e;
                };
            } else {
                break :blk Map.Perms.rw;
            }
        };
        const map = Map.create(mr, pd.getMapVaddr(&mr), perms, .{
            .cached = region_resource.cached,
            .setvar_vaddr = region_resource.setvar_vaddr,
        });
        pd.addMap(map);
        device_res.regions[pci_bar.region_idx] = .{
            .region = .{
                // The driver that is consuming the device region wants to know about the
                // region that is specifeid in the DTB node, rather than the start of the region that
                // is mapped. While uncommon, sometimes the device region is not page-aligned unlike
                // the mapping.
                .vaddr = map.vaddr,
                .size = map.mr.size,
            },
            .io_addr = map.mr.paddr.?,
        };

        const base_addr = blk: {
            switch (pci_bar.mem_mapped.?) {
                true => {
                    if (pci_bar.region_idx > device_res.num_regions) {
                        log.err("invalid region_idx {} > num_regions {}", .{pci_bar.region_idx, device_res.num_regions});
                        return error.InvalidPciConfig;
                    }
                    break :blk device_res.regions[pci_bar.region_idx].io_addr;
                },
                false => {
                    if (pci_bar.region_idx > device_res.num_ioports) {
                        log.err("invalid ioport_idx {} > num_ioports {}", .{pci_bar.region_idx, device_res.num_ioports});
                        return error.InvalidPciConfig;
                    }
                    break :blk device_res.ioports[pci_bar.region_idx].base_addr;
                }
            }
        };

        if (requested_bars[pci_bar.bar_id].base_addr != 0) {
            log.err("PCI BAR {} has been used", .{pci_bar.bar_id});
            return error.InvalidPciConfig;
        }

        requested_bars[pci_bar.bar_id] = .{
            .bar_id = pci_bar.bar_id,
            .base_addr = base_addr,
            .mem_mapped = pci_bar.mem_mapped.?,
            .mem_64b = pci_bar.mem_64b.?,
        };

        if (pci_bar.mem_64b == true) {
            requested_bars[pci_bar.bar_id + 1] = .{
                .bar_id = pci_bar.bar_id,
                .base_addr = base_addr,
                .mem_mapped = pci_bar.mem_mapped.?,
                .mem_64b = pci_bar.mem_64b.?,
            };
        }
    }

    return .{
        .bus = dev.pci_bus,
        .dev = dev.pci_dev,
        .func = dev.pci_func,
        .device_id = dev.device_id,
        .vendor_id = dev.vendor_id,
        .bars = requested_bars,
        .num_irqs = requested_num_irqs,
        .irqs = requested_irqs,
    };
}
