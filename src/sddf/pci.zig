const std = @import("std");
const mod_sdf = @import("../sdf.zig");
const dtb = @import("../dtb.zig");
const data = @import("../data.zig");
const log = @import("../log.zig");
const sddf = @import("sddf.zig");

const fmt = sddf.fmt;
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Pd = SystemDescription.ProtectionDomain;
const Irq = SystemDescription.Irq;

const ConfigResources = data.Resources;

const SystemError = sddf.SystemError;
const DeviceInfo = sddf.Config.DeviceInfo;

pub const Pci = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device_res: ConfigResources.Device,
    clients: std.array_list.Managed(PciClient),
    client_config: ConfigResources.Pci.PciConfig,
    ecam_paddr: u64,
    ecam_size: u64,
    mmio_paddr_base: u64,
    mmio_paddr_top: u64,

    connected: bool = false,
    serialised: bool = false,

    pub const PciClient = struct {
        class: sddf.Config.Driver.Class,
        subsystem: *align(8)anyopaque,
        dev: DeviceOptions,
    };

    pub const Error = SystemError || error{
        InvalidClient,
        ClientNotConnected,
        InvalidPciConfig,
    };

    pub const DeviceOptions = struct {
        pci_bus: u8,
        pci_dev: u8,
        pci_func: u8,
        device_id: u16,
        vendor_id: u16,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, driver: *Pd, ecam_paddr: u64, ecam_size: u64, mmio_paddr: u64, mmio_size: u64) Pci {

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .clients = std.array_list.Managed(PciClient).init(allocator),
            .client_config = std.mem.zeroInit(ConfigResources.Pci.PciConfig, .{}),
            .ecam_paddr = ecam_paddr,
            .ecam_size = ecam_size,
            .mmio_paddr_base = mmio_paddr,
            .mmio_paddr_top = mmio_paddr + mmio_size,
        };
    }

    pub fn deinit(_: *Pci) void {
    }

    pub fn addClient(system: *Pci, class: sddf.Config.Driver.Class, subsystem: *align(8)anyopaque, options: DeviceOptions) Error!void {

        for (system.clients.items) |client| {
            if (client.subsystem == subsystem) {
                return Error.DuplicateClient;
            }
        }

        system.clients.append(.{
            .class = class,
            .subsystem = subsystem,
            .dev = options,
        }) catch @panic("Could not add client to Pci");
    }

    pub fn addMemoryRegion(system: *Pci, paddr: u64, size: u64, name: []const u8) void {
        const mr = Mr.physical(system.allocator, system.sdf, name, size, .{ .paddr = paddr });
        system.sdf.addMemoryRegion(mr);
        const map = Map.create(mr, system.driver.getMapVaddr(&mr), Map.Perms.rw, .{});
        system.driver.addMap(map);
        system.device_res.regions[system.device_res.num_regions] = .{
            .region = .{
                .vaddr = map.vaddr,
                .size = map.mr.size,
            },
            .io_addr = map.mr.paddr.?,
        };
        system.device_res.num_regions += 1;

    }

    pub fn connect(system: *Pci) !void {
        system.addMemoryRegion(system.ecam_paddr, system.ecam_size, "ecam_region");

        for (system.clients.items) |client| {
            switch (client.class) {
                .blk => {
                    log.debug("connect blk to pci host", .{});
                    const blk: *sddf.Blk = @ptrCast(client.subsystem);

                    const config = try sddf.composePciConfig(system, blk.driver, blk.compatible.?, .blk, &blk.device_res, client.dev);

                    system.client_config.requests[system.client_config.num_requests] = config;
                    system.client_config.num_requests += 1;
                },
                else => @panic("client is not supported")
            }
        }
        system.connected = true;
    }

    pub fn serialiseConfig(system: *Pci, prefix: []const u8) !void {
        const device_res_data_name = fmt(system.allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(system.allocator, system.device_res, prefix, device_res_data_name);

        const client_configs_name = fmt(system.allocator, "{s}_client_configs", .{system.driver.name});
        try data.serialize(system.allocator, system.client_config, prefix, client_configs_name);

        system.serialised = true;
    }
};
