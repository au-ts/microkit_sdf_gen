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

pub const Timer = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    /// Protection Domain that will act as the driver for the timer
    driver: *Pd,
    /// Device Tree node for the timer device
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    /// Client PDs serviced by the timer driver
    clients: std.array_list.Managed(*Pd),
    client_configs: std.array_list.Managed(ConfigResources.Timer.Client),
    connected: bool = false,
    serialised: bool = false,

    pub const Error = SystemError;

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd) Timer {
        // First we have to set some properties on the driver. It is currently our policy that every timer
        // driver should be passive.
        driver.passive = true;

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .client_configs = std.array_list.Managed(ConfigResources.Timer.Client).init(allocator),
        };
    }

    pub fn deinit(system: *Timer) void {
        system.clients.deinit();
        system.client_configs.deinit();
    }

    pub fn addClient(system: *Timer, client: *Pd) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        if (std.mem.eql(u8, client.name, system.driver.name)) {
            log.err("invalid timer client, same name as driver '{s}", .{client.name});
            return Error.InvalidClient;
        }
        const client_priority = if (client.priority) |priority| priority else Pd.DEFAULT_PRIORITY;
        const driver_priority = if (system.driver.priority) |priority| priority else Pd.DEFAULT_PRIORITY;
        if (client_priority >= driver_priority) {
            log.err("invalid timer client '{s}', driver '{s}' must have greater priority than client", .{ client.name, system.driver.name });
            return Error.InvalidClient;
        }
        system.clients.append(client) catch @panic("Could not add client to Timer");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Timer.Client, .{})) catch @panic("Could not add client to Timer");
    }

    pub fn connect(system: *Timer) !void {
        // The driver must be passive
        std.debug.assert(system.driver.passive.?);

        if (system.device) | dtb_node | {
            try sddf.createDriver(system.sdf, system.driver, dtb_node, .timer, &system.device_res);
        }
        for (system.clients.items, 0..) |client, i| {
            const ch = Channel.create(system.driver, client, .{
                // Client needs to be able to PPC into driver
                .pp = .b,
                // Client does not need to notify driver
                .pd_b_notify = false,
            }) catch unreachable;
            system.sdf.addChannel(ch);
            system.client_configs.items[i].driver_id = ch.pd_b_id;
        }

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Timer, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);

        for (system.clients.items, 0..) |client, i| {
            const data_name = fmt(allocator, "timer_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, data_name);
        }

        system.serialised = true;
    }
};
