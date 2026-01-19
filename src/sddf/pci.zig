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

const ConfigResources = data.Resources;

const SystemError = sddf.SystemError;
const DeviceInfo = sddf.Config.DeviceInfo;

pub const Pci = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    clients: std.array_list.Managed(PciClient),
    client_config: ConfigResources.Pci.EcamConfig,

    connected: bool = false,
    serialised: bool = false,


    pub const PciClient = struct {
        class: sddf.Config.Driver.Class,
        subsystem: *align(8)anyopaque,
    };

    pub const Error = SystemError || error{
        InvalidClient,
        ClientNotConnected,
        InvalidPciConfig,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd) Pci {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .clients = std.array_list.Managed(PciClient).init(allocator),
            .client_config = std.mem.zeroInit(ConfigResources.Pci.EcamConfig, .{}),
        };
    }

    pub fn deinit(_: *Pci) void {
    }

    fn addConfigRequest(system: *Pci, pci_cfg: ?sddf.PciConfig) Error!void {
        log.debug("add config request", .{});
        if (pci_cfg) |cfg| {
            log.debug("bus: {any}, dev: {any}", .{cfg.pci_bus, cfg.pci_dev});
            system.client_config.requests[system.client_config.num_requests] = .{
                .bus = cfg.pci_bus,
                .dev = cfg.pci_dev,
                .func = cfg.pci_func,
                .device_id = cfg.device_id,
                .vendor_id = cfg.vendor_id,
                .irq_type = cfg.irq_type,
                .bars = cfg.pci_bars,
            };
            system.client_config.num_requests += 1;
            // system.client_config.num_requests = 156;
        } else {
            return Error.InvalidPciConfig;
        }
    }

    pub fn addClient(system: *Pci, class: sddf.Config.Driver.Class, subsystem: *align(8)anyopaque) Error!void {

        for (system.clients.items) |client| {
            if (client.subsystem == subsystem) {
                return Error.DuplicateClient;
            }
        }

        system.clients.append(.{
            .class = class,
            .subsystem = subsystem
        }) catch @panic("Could not add client to Pci");

    }

    pub fn addEcam(system: *Pci, paddr: u64, size: u64) void {
        log.debug("blk driver class: {}", .{ @intFromEnum(sddf.Config.Driver.Class.blk) });

        const mr_name = fmt(system.allocator, "pci_driver/ecam_{any}", .{ system.device_res.num_regions });
        const mr = Mr.physical(system.allocator, system.sdf, mr_name, size, .{ .paddr = paddr });
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
        for (system.clients.items) |client| {
            switch (client.class) {
                .blk => {
                    log.debug("connect blk to pci host", .{});
                    const blk: *sddf.Blk = @ptrCast(client.subsystem);

                    log.debug("compatible: {s}", .{ blk.dev_info.?.name });
                    try system.addConfigRequest(blk.dev_info);
                },
                else => @panic("client is not supported")
            }
        }
        system.connected = true;
    }

    pub fn serialiseConfig(system: *Pci, prefix: []const u8) !void {
        const device_res_data_name = fmt(system.allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(system.allocator, system.device_res, prefix, device_res_data_name);

        log.debug("raw: {any}", .{system.client_config});
        const client_configs_name = fmt(system.allocator, "{s}_client_configs", .{system.driver.name});
        try data.serialize(system.allocator, system.client_config, prefix, client_configs_name);

        system.serialised = true;
    }
};
