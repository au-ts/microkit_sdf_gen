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
const Channel = SystemDescription.Channel;

const ConfigResources = data.Resources;

const SystemError = sddf.SystemError;

pub const Pinctrl = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    /// Protection Domain that will act as the driver for the pinmux device
    driver: *Pd,
    /// Device Tree node for the pinctrl device
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    serialised: bool = false,
    connected: bool = false,

    pub const Error = SystemError;

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd) Pinctrl {
        // Set some properties on the driver. It is currently our policy that every pinctrl
        // driver should be passive.
        driver.passive = true;

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
        };
    }

    pub fn deinit(system: *Pinctrl) void {
        // In the future when we add clients we would need to free associated resources here
        _ = system;
        return;
    }

    pub fn connect(system: *Pinctrl) !void {
        // The driver must be passive
        std.debug.assert(system.driver.passive.?);

        // The driver must be at the highest priority exclusively
        const pinctrl_pd_prio = system.driver.priority;
        for (system.sdf.pds.items) |pd| {
            if (pd != system.driver and pd.priority.? >= pinctrl_pd_prio.?) {
                @panic("Pinctrl driver PD must be exclusively at the highest priority.");
            }
        }

        try sddf.createDriver(system.sdf, system.driver, system.device, .pinctrl, &system.device_res);
        system.connected = true;
    }

    pub fn serialiseConfig(system: *Pinctrl, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);

        system.serialised = true;
    }
};