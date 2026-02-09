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

pub const Gpio = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    clients: std.ArrayList(Client),
    client_configs: std.ArrayList(ConfigResources.Gpio.Client),
    connected: bool = false,
    serialised: bool = false,

    const MAX_CHANNELS = 62;

    pub const Client = struct {
        pd: *Pd,
        driver_channel_ids: []u8,
    };

    pub const ClientOptions = struct {
        driver_channel_ids: ?[]const u8 = null,
    };

    pub const Error = SystemError || error{
        InvalidOptions,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd) Gpio {
        // First we have to set some properties on the driver. It is currently our policy that every gpio
        // driver should be passive.
        driver.passive = true;

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .clients = std.ArrayList(Client).init(allocator),
            .client_configs = std.ArrayList(ConfigResources.Gpio.Client).init(allocator),
        };
    }

    pub fn deinit(system: *Gpio) void {
        for (system.clients.items) |c| {
            system.allocator.free(c.driver_channel_ids);
        }
        system.clients.deinit();
        system.client_configs.deinit();
    }

    pub fn addClient(system: *Gpio, client: *Pd, options: ClientOptions) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.pd.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        if (std.mem.eql(u8, client.name, system.driver.name)) {
            log.err("invalid gpio client, same name as driver '{s}", .{client.name});
            return Error.InvalidClient;
        }
        const client_priority = if (client.priority) |priority| priority else Pd.DEFAULT_PRIORITY;
        const driver_priority = if (system.driver.priority) |priority| priority else Pd.DEFAULT_PRIORITY;
        if (client_priority >= driver_priority) {
            log.err("invalid gpio client '{s}', driver '{s}' must have greater priority than client", .{ client.name, system.driver.name });
            return Error.InvalidClient;
        }
        if (options.driver_channel_ids == null) {
            log.err("cannot pass null for driver_channel_ids option in driver for client '{s}'", .{client.name});
            return Error.InvalidOptions;
        }

        const ids = options.driver_channel_ids.?;

        if (ids.len == 0) {
            log.err("must request at least one GPIO channel inside option in driver for client '{s}'", .{client.name});
            return Error.InvalidOptions;
        }
        if (ids.len > MAX_CHANNELS) {
            log.err("requesting too many GPIO channels inside option in driver for client '{s}'", .{client.name});
            return Error.InvalidOptions;
        }

        // make sure the channel numbers are valid
        for (ids, 0..) |driver_id, i| {
            if (driver_id > MAX_CHANNELS) {
                log.err("invalid driver_id at index '{d}' options.driver_channel_ids in driver for client '{s}'", .{ i, client.name });
                return Error.InvalidOptions;
            }
        }

        // check that there are no duplicates in other clients
        for (system.clients.items) |existing_client| {
            for (existing_client.driver_channel_ids) |existing_id| {
                for (ids) |new_id| {
                    if (existing_id == new_id) {
                        log.err("driver_id {d} already assigned to another client ('{s}'), cannot reassign to '{s}'", .{ new_id, existing_client.pd.name, client.name });
                        return Error.InvalidOptions;
                    }
                }
            }
        }

        const new_driver_channel_ids_buf = system.allocator.dupe(u8, ids) catch @panic("OOM allocating GPIO driver_channel_ids");
        system.clients.append(.{
            .pd = client,
            .driver_channel_ids = new_driver_channel_ids_buf,
        }) catch @panic("Could not add client to Gpio");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Gpio.Client, .{})) catch @panic("Could not add client to Gpio");
    }

    pub fn connect(system: *Gpio) !void {
        // The driver must be passive
        assert(system.driver.passive.?);

        try createDriver(system.sdf, system.driver, system.device, .gpio, &system.device_res);

        // For each client...
        for (system.clients.items, 0..) |client, i| {
            // for each requested channel
            for (client.driver_channel_ids, 0..) |id, j| {
                const ch = Channel.create(system.driver, client.pd, .{
                    // Client needs to be able to PPC into driver
                    .pp = .b,
                    // Client does not need to notify driver
                    .pd_b_notify = false,
                    // We need to explictly choose the channel id in the driver
                    // to honour the options and config file
                    .pd_a_id = id,
                }) catch unreachable;
                system.sdf.addChannel(ch);

                // store the client side POV channel in client config
                system.client_configs.items[i].driver_channel_ids[j] = ch.pd_b_id;
                system.client_configs.items[i].num_driver_channel_ids += 1;
            }
        }

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Gpio, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);

        for (system.clients.items, 0..) |client, i| {
            const data_name = fmt(allocator, "gpio_client_{s}", .{client.pd.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, data_name);
        }

        system.serialised = true;
    }
};
