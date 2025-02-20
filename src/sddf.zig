const std = @import("std");
const mod_sdf = @import("sdf.zig");
const dtb = @import("dtb.zig");
const data = @import("data.zig");
const log = @import("log.zig");

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
var drivers: std.ArrayList(Config.Driver) = undefined;
var classes: std.ArrayList(Config.DeviceClass) = undefined;

const CONFIG_FILENAME = "config.json";

/// Whether or not we have probed sDDF
// TODO: should probably just happen upon `init` of sDDF, then
// we pass around sddf everywhere?
var probed = false;

fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) []u8 {
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
    var array = try std.ArrayList([]const u8).initCapacity(allocator, num_compatible);
    for (drivers.items) |driver| {
        for (driver.compatible) |compatible| {
            array.appendAssumeCapacity(compatible);
        }
    }

    return try array.toOwnedSlice();
}

// pub fn wasmProbe(allocator: Allocator, driverConfigs: anytype, classConfigs: anytype) !void {
//     drivers = std.ArrayList(Config.Driver).init(allocator);
//     classes = std.ArrayList(Config.DeviceClass).initCapacity(allocator, @typeInfo(Config.DeviceClass).Enum.fields.len);

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
    drivers = std.ArrayList(Config.Driver).init(allocator);

    log.debug("starting sDDF probe", .{});
    log.debug("opening sDDF root dir '{s}'", .{path});
    var sddf = fs.cwd().openDir(path, .{}) catch |e| {
        log.err("failed to open sDDF directory '{s}': {}", .{ path, e });
        return e;
    };
    defer sddf.close();

    const device_classes = comptime std.meta.fields(Config.Driver.Class);
    inline for (device_classes) |device_class| {
        var checked_compatibles = std.ArrayList([]const u8).init(allocator);
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
                const config_file_stat = config_file.stat() catch |e| {
                    log.err("failed to stat driver config file: {s}: {}", .{ config_path, e });
                    return e;
                };
                const config_bytes = try config_file.reader().readAllAlloc(allocator, config_file_stat.size);
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
                const config = Config.Driver.fromJson(json, device_class.name, driver_dir) catch unreachable;

                // Check IRQ resources are valid
                var checked_irqs = std.ArrayList(DeviceTreeIndex).init(allocator);
                defer checked_irqs.deinit();
                for (config.resources.irqs) |irq| {
                    for (checked_irqs.items) |checked_dt_index| {
                        if (irq.dt_index == checked_dt_index) {
                            log.err("duplicate irq dt_index value '{}' for driver '{s}'", .{ irq.dt_index, driver_dir });
                            return error.InvalidConfig;
                        }
                    }
                    try checked_irqs.append(irq.dt_index);
                }

                // Check region resources are valid
                var checked_regions = std.ArrayList(Config.Region).init(allocator);
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
        dt_index: DeviceTreeIndex,
    };

    /// In the case of drivers there is some extra information we want
    /// to store that is not specified in the JSON configuration.
    /// For example, the device class that the driver belongs to.
    pub const Driver = struct {
        dir: []const u8,
        class: Class,
        compatible: []const []const u8,
        resources: Resources,

        const Resources = struct {
            regions: []const Region,
            irqs: []const Config.Irq,
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
        const Class = enum {
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
                    .network => &.{"network"},
                    .serial => &.{"serial"},
                    .timer => &.{"timer"},
                    .blk => &.{ "blk", "blk/mmc" },
                    .i2c => &.{"i2c"},
                    .gpu => &.{"gpu"},
                };
            }
        };
    };
};

const SystemError = error{
    NotConnected,
    InvalidClient,
    DuplicateClient,
};

pub const Timer = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    /// Protection Domain that will act as the driver for the timer
    driver: *Pd,
    /// Device Tree node for the timer device
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    /// Client PDs serviced by the timer driver
    clients: std.ArrayList(*Pd),
    client_configs: std.ArrayList(ConfigResources.Timer.Client),
    connected: bool = false,
    serialised: bool = false,

    pub const Error = SystemError;

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd) Timer {
        // First we have to set some properties on the driver. It is currently our policy that every timer
        // driver should be passive.
        driver.passive = true;

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .clients = std.ArrayList(*Pd).init(allocator),
            .client_configs = std.ArrayList(ConfigResources.Timer.Client).init(allocator),
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
        assert(system.driver.passive.?);

        try createDriver(system.sdf, system.driver, system.device, .timer, &system.device_res);
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

pub const I2c = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.ArrayList(*Pd),
    region_req_size: usize,
    region_resp_size: usize,
    region_data_size: usize,
    driver_config: ConfigResources.I2c.Driver,
    virt_config: ConfigResources.I2c.Virt,
    client_configs: std.ArrayList(ConfigResources.I2c.Client),
    num_buffers: u16,
    connected: bool = false,
    serialised: bool = false,

    pub const Error = SystemError;

    pub const Options = struct {
        region_req_size: usize = 0x1000,
        region_resp_size: usize = 0x1000,
        region_data_size: usize = 0x1000,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd, virt: *Pd, options: Options) I2c {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = std.ArrayList(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt = virt,
            .region_req_size = options.region_req_size,
            .region_resp_size = options.region_resp_size,
            .region_data_size = options.region_data_size,
            .driver_config = std.mem.zeroInit(ConfigResources.I2c.Driver, .{}),
            .virt_config = std.mem.zeroInit(ConfigResources.I2c.Virt, .{}),
            .client_configs = std.ArrayList(ConfigResources.I2c.Client).init(allocator),
            // TODO: handle properly
            .num_buffers = 128,
        };
    }

    pub fn deinit(system: *I2c) void {
        system.clients.deinit();
        system.client_configs.deinit();
    }

    pub fn addClient(system: *I2c, client: *Pd) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        if (std.mem.eql(u8, client.name, system.driver.name)) {
            log.err("invalid I2C client, same name as driver '{s}", .{client.name});
            return Error.InvalidClient;
        }
        if (std.mem.eql(u8, client.name, system.virt.name)) {
            log.err("invalid I2C client, same name as virt '{s}", .{client.name});
            return Error.InvalidClient;
        }
        system.clients.append(client) catch @panic("Could not add client to I2c");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.I2c.Client, .{})) catch @panic("Could not add client to I2c");
    }

    pub fn connectDriver(system: *I2c) void {
        const allocator = system.allocator;
        var sdf = system.sdf;
        var driver = system.driver;
        var virt = system.virt;

        // Create all the MRs between the driver and virtualiser
        const mr_req = Mr.create(allocator, "i2c_driver_request", system.region_req_size, .{});
        const mr_resp = Mr.create(allocator, "i2c_driver_response", system.region_resp_size, .{});

        sdf.addMemoryRegion(mr_req);
        sdf.addMemoryRegion(mr_resp);

        const driver_map_req = Map.create(mr_req, driver.getMapVaddr(&mr_req), .rw, .{});
        driver.addMap(driver_map_req);
        const driver_map_resp = Map.create(mr_resp, driver.getMapVaddr(&mr_resp), .rw, .{});
        driver.addMap(driver_map_resp);

        const virt_map_req = Map.create(mr_req, virt.getMapVaddr(&mr_req), .rw, .{});
        virt.addMap(virt_map_req);
        const virt_map_resp = Map.create(mr_resp, virt.getMapVaddr(&mr_resp), .rw, .{});
        virt.addMap(virt_map_resp);

        const ch = Channel.create(system.driver, system.virt, .{}) catch unreachable;
        sdf.addChannel(ch);

        system.driver_config = .{
            .virt = .{
                // Will be set in connectClient
                .data = undefined,
                .req_queue = .createFromMap(driver_map_req),
                .resp_queue = .createFromMap(driver_map_resp),
                .num_buffers = system.num_buffers,
                .id = ch.pd_a_id,
            },
        };

        system.virt_config.driver = .{
            // Will be set in connectClient
            .data = undefined,
            .req_queue = .createFromMap(virt_map_req),
            .resp_queue = .createFromMap(virt_map_resp),
            .num_buffers = system.num_buffers,
            .id = ch.pd_b_id,
        };
    }

    pub fn connectClient(system: *I2c, client: *Pd, i: usize) void {
        const allocator = system.allocator;
        var sdf = system.sdf;
        const virt = system.virt;
        var driver = system.driver;

        system.virt_config.num_clients += 1;

        const mr_req = Mr.create(allocator, fmt(allocator, "i2c_client_request_{s}", .{client.name}), system.region_req_size, .{});
        const mr_resp = Mr.create(allocator, fmt(allocator, "i2c_client_response_{s}", .{client.name}), system.region_resp_size, .{});
        const mr_data = Mr.create(allocator, fmt(allocator, "i2c_client_data_{s}", .{client.name}), system.region_data_size, .{});

        sdf.addMemoryRegion(mr_req);
        sdf.addMemoryRegion(mr_resp);
        sdf.addMemoryRegion(mr_data);

        const driver_map_data = Map.create(mr_data, system.driver.getMapVaddr(&mr_data), .rw, .{});
        driver.addMap(driver_map_data);

        const virt_map_req = Map.create(mr_req, system.virt.getMapVaddr(&mr_req), .rw, .{});
        virt.addMap(virt_map_req);
        const virt_map_resp = Map.create(mr_resp, system.virt.getMapVaddr(&mr_resp), .rw, .{});
        virt.addMap(virt_map_resp);

        const client_map_req = Map.create(mr_req, client.getMapVaddr(&mr_req), .rw, .{});
        client.addMap(client_map_req);
        const client_map_resp = Map.create(mr_resp, client.getMapVaddr(&mr_resp), .rw, .{});
        client.addMap(client_map_resp);
        const client_map_data = Map.create(mr_data, client.getMapVaddr(&mr_data), .rw, .{});
        client.addMap(client_map_data);

        // Create a channel between the virtualiser and client
        const ch = Channel.create(virt, client, .{ .pp = .b }) catch unreachable;
        sdf.addChannel(ch);

        system.virt_config.clients[i] = .{
            .conn = .{
                .data = .{
                    // TODO: absolute hack
                    .vaddr = 0,
                    .size = system.region_data_size,
                },
                .req_queue = .createFromMap(virt_map_req),
                .resp_queue = .createFromMap(virt_map_resp),
                .num_buffers = system.num_buffers,
                .id = ch.pd_a_id,
            },
            .driver_data_offset = i * system.region_data_size,
        };
        if (i == 0) {
            system.driver_config.virt.data = .createFromMap(driver_map_data);
        }

        system.client_configs.items[i] = .{ .virt = .{
            .data = .createFromMap(client_map_data),
            .req_queue = .createFromMap(client_map_req),
            .resp_queue = .createFromMap(client_map_resp),
            .num_buffers = system.num_buffers,
            .id = ch.pd_b_id,
        } };
    }

    pub fn connect(system: *I2c) !void {
        const sdf = system.sdf;

        // 1. Create the device resources for the driver
        if (system.device) |device| {
            try createDriver(sdf, system.driver, device, .i2c, &system.device_res);
        }
        // 2. Connect the driver to the virtualiser
        system.connectDriver();

        // 3. Connect each client to the virtualiser
        for (system.clients.items, 0..) |client, i| {
            system.connectClient(client, i);
        }

        // To avoid cross-core IPC, we make the virtualiser passive
        system.virt.passive = true;

        system.connected = true;
    }

    pub fn serialiseConfig(system: *I2c, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(system.allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.driver_config, prefix, "i2c_driver");
        try data.serialize(allocator, system.virt_config, prefix, "i2c_virt");

        for (system.clients.items, 0..) |client, i| {
            const name = fmt(allocator, "i2c_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, name);
        }

        system.serialised = true;
    }
};

pub const Blk = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.ArrayList(*Pd),
    client_partitions: std.ArrayList(u32),
    connected: bool = false,
    serialised: bool = false,
    // TODO: make this configurable per component
    queue_mr_size: usize = 2 * 1024 * 1024,
    // TODO: make configurable
    queue_capacity: u16 = 128,
    config: Blk.Config,

    const Config = struct {
        driver: ConfigResources.Blk.Driver = undefined,
        virt_driver: ConfigResources.Blk.Virt.Driver = undefined,
        virt_clients: std.ArrayList(ConfigResources.Blk.Virt.Client),
        clients: std.ArrayList(ConfigResources.Blk.Client),
    };

    pub const Error = SystemError || error{
        InvalidVirt,
    };

    pub const Options = struct {};

    const STORAGE_INFO_REGION_SIZE: usize = 0x1000;

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd, virt: *Pd, _: Options) Error!Blk {
        if (std.mem.eql(u8, driver.name, virt.name)) {
            log.err("invalid blk virtualiser, same name as driver '{s}", .{virt.name});
            return Error.InvalidVirt;
        }
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = std.ArrayList(*Pd).init(allocator),
            .client_partitions = std.ArrayList(u32).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt = virt,
            .config = .{
                .virt_clients = .init(allocator),
                .clients = .init(allocator),
            },
        };
    }

    pub fn deinit(system: *Blk) void {
        system.clients.deinit();
        system.client_partitions.deinit();
        system.config.virt_clients.deinit();
        system.config.clients.deinit();
    }

    pub const ClientOptions = struct {
        partition: u32,
    };

    pub fn addClient(system: *Blk, client: *Pd, options: ClientOptions) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        if (std.mem.eql(u8, client.name, system.driver.name)) {
            log.err("invalid blk client, same name as driver '{s}", .{client.name});
            return Error.InvalidClient;
        }
        if (std.mem.eql(u8, client.name, system.virt.name)) {
            log.err("invalid blk client, same name as virt '{s}", .{client.name});
            return Error.InvalidClient;
        }
        system.clients.append(client) catch @panic("Could not add client to Blk");
        system.client_partitions.append(options.partition) catch @panic("Could not add client to Blk");
    }

    pub fn connectDriver(system: *Blk) void {
        const sdf = system.sdf;
        const allocator = system.allocator;
        const driver = system.driver;
        const virt = system.virt;

        const mr_storage_info = Mr.create(allocator, "blk_driver_storage_info", STORAGE_INFO_REGION_SIZE, .{});
        const map_storage_info_driver = Map.create(mr_storage_info, system.driver.getMapVaddr(&mr_storage_info), .rw, .{});
        const map_storage_info_virt = Map.create(mr_storage_info, system.virt.getMapVaddr(&mr_storage_info), .r, .{});

        sdf.addMemoryRegion(mr_storage_info);
        driver.addMap(map_storage_info_driver);
        virt.addMap(map_storage_info_virt);

        const mr_req = Mr.create(allocator, "blk_driver_request", system.queue_mr_size, .{});
        const map_req_driver = Map.create(mr_req, driver.getMapVaddr(&mr_req), .rw, .{});
        const map_req_virt = Map.create(mr_req, virt.getMapVaddr(&mr_req), .rw, .{});

        sdf.addMemoryRegion(mr_req);
        driver.addMap(map_req_driver);
        virt.addMap(map_req_virt);

        const mr_resp = Mr.create(allocator, "blk_driver_response", system.queue_mr_size, .{});
        const map_resp_driver = Map.create(mr_resp, driver.getMapVaddr(&mr_resp), .rw, .{});
        const map_resp_virt = Map.create(mr_resp, virt.getMapVaddr(&mr_resp), .rw, .{});

        sdf.addMemoryRegion(mr_resp);
        driver.addMap(map_resp_driver);
        virt.addMap(map_resp_virt);

        const mr_data = Mr.physical(allocator, sdf, "blk_driver_data", system.queue_mr_size, .{});
        const map_data_virt = Map.create(mr_data, virt.getMapVaddr(&mr_data), .rw, .{});

        sdf.addMemoryRegion(mr_data);
        virt.addMap(map_data_virt);

        const ch = Channel.create(system.virt, system.driver, .{}) catch unreachable;
        system.sdf.addChannel(ch);

        system.config.driver = .{
            .virt = .{
                .storage_info = .createFromMap(map_storage_info_driver),
                .req_queue = .createFromMap(map_req_driver),
                .resp_queue = .createFromMap(map_resp_driver),
                .num_buffers = system.queue_capacity,
                .id = ch.pd_b_id,
            },
        };

        system.config.virt_driver = .{
            .conn = .{
                .storage_info = .createFromMap(map_storage_info_virt),
                .req_queue = .createFromMap(map_req_virt),
                .resp_queue = .createFromMap(map_resp_virt),
                .num_buffers = system.queue_capacity,
                .id = ch.pd_a_id,
            },
            .data = .createFromMap(map_data_virt),
        };
    }

    pub fn connectClient(system: *Blk, client: *Pd, i: usize) void {
        const sdf = system.sdf;
        const allocator = system.allocator;
        const queue_mr_size = system.queue_mr_size;

        const mr_storage_info = Mr.create(allocator, fmt(allocator, "blk_client_{s}_storage_info", .{client.name}), STORAGE_INFO_REGION_SIZE, .{});
        const map_storage_info_virt = Map.create(mr_storage_info, system.virt.getMapVaddr(&mr_storage_info), .rw, .{});
        const map_storage_info_client = Map.create(mr_storage_info, client.getMapVaddr(&mr_storage_info), .r, .{});

        system.sdf.addMemoryRegion(mr_storage_info);
        system.virt.addMap(map_storage_info_virt);
        client.addMap(map_storage_info_client);

        const mr_req = Mr.create(allocator, fmt(allocator, "blk_client_{s}_request", .{client.name}), queue_mr_size, .{});
        const map_req_virt = Map.create(mr_req, system.virt.getMapVaddr(&mr_req), .rw, .{});
        const map_req_client = Map.create(mr_req, client.getMapVaddr(&mr_req), .rw, .{});

        system.sdf.addMemoryRegion(mr_req);
        system.virt.addMap(map_req_virt);
        client.addMap(map_req_client);

        const mr_resp = Mr.create(allocator, fmt(allocator, "blk_client_{s}_response", .{client.name}), queue_mr_size, .{});
        const map_resp_virt = Map.create(mr_resp, system.virt.getMapVaddr(&mr_resp), .rw, .{});
        const map_resp_client = Map.create(mr_resp, client.getMapVaddr(&mr_resp), .rw, .{});

        system.sdf.addMemoryRegion(mr_resp);
        system.virt.addMap(map_resp_virt);
        client.addMap(map_resp_client);

        const mr_data = Mr.physical(allocator, sdf, fmt(allocator, "blk_client_{s}_data", .{client.name}), queue_mr_size, .{});
        const map_data_virt = Map.create(mr_data, system.virt.getMapVaddr(&mr_data), .rw, .{});
        const map_data_client = Map.create(mr_data, client.getMapVaddr(&mr_data), .rw, .{});

        system.sdf.addMemoryRegion(mr_data);
        system.virt.addMap(map_data_virt);
        client.addMap(map_data_client);

        const ch = Channel.create(system.virt, client, .{}) catch unreachable;
        system.sdf.addChannel(ch);

        system.config.virt_clients.append(.{
            .conn = .{
                .storage_info = .createFromMap(map_storage_info_virt),
                .req_queue = .createFromMap(map_req_virt),
                .resp_queue = .createFromMap(map_resp_virt),
                .num_buffers = system.queue_capacity,
                .id = ch.pd_a_id,
            },
            .data = .createFromMap(map_data_virt),
            .partition = system.client_partitions.items[i],
        }) catch @panic("could not add virt client config");

        system.config.clients.append(.{ .virt = .{
            .storage_info = .createFromMap(map_storage_info_client),
            .req_queue = .createFromMap(map_req_client),
            .resp_queue = .createFromMap(map_resp_client),
            .num_buffers = system.queue_capacity,
            .id = ch.pd_b_id,
        }, .data = .createFromMap(map_data_client) }) catch @panic("could not add client config");
    }

    pub fn connect(system: *Blk) !void {
        const sdf = system.sdf;

        // 1. Create the device resources for the driver
        try createDriver(sdf, system.driver, system.device, .blk, &system.device_res);
        // 2. Connect the driver to the virtualiser
        system.connectDriver();
        // 3. Connect each client to the virtualiser
        for (system.clients.items, 0..) |client, i| {
            system.connectClient(client, i);
        }

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Blk, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.config.driver, prefix, "blk_driver");
        const virt_config = ConfigResources.Blk.Virt.create(system.config.virt_driver, system.config.virt_clients.items);
        try data.serialize(allocator, virt_config, prefix, "blk_virt");

        for (system.config.clients.items, 0..) |config, i| {
            const client_config = fmt(allocator, "blk_client_{s}", .{system.clients.items[i].name});
            try data.serialize(allocator, config, prefix, client_config);
        }

        system.serialised = true;
    }
};

pub const Serial = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    data_size: usize,
    queue_size: usize,
    driver: *Pd,
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    virt_rx: ?*Pd,
    virt_tx: *Pd,
    clients: std.ArrayList(*Pd),
    connected: bool = false,
    enable_color: bool,
    serialised: bool = false,

    driver_config: ConfigResources.Serial.Driver,
    virt_rx_config: ConfigResources.Serial.VirtRx,
    virt_tx_config: ConfigResources.Serial.VirtTx,
    client_configs: std.ArrayList(ConfigResources.Serial.Client),

    pub const Error = SystemError || error{
        InvalidVirt,
    };

    pub const Options = struct {
        data_size: usize = 0x10000,
        queue_size: usize = 0x1000,
        virt_rx: ?*Pd = null,
        enable_color: bool = true,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd, virt_tx: *Pd, options: Options) Error!Serial {
        if (std.mem.eql(u8, driver.name, virt_tx.name)) {
            log.err("invalid serial tx virtualiser, same name as driver '{s}", .{virt_tx.name});
            return Error.InvalidVirt;
        }
        if (options.virt_rx) |virt_rx| {
            if (std.mem.eql(u8, driver.name, virt_rx.name)) {
                log.err("invalid serial rx virtualiser, same name as driver '{s}", .{virt_rx.name});
                return Error.InvalidVirt;
            }
            if (std.mem.eql(u8, virt_tx.name, virt_rx.name)) {
                log.err("invalid serial rx virtualiser, same name as tx virtualiser '{s}", .{virt_rx.name});
                return Error.InvalidVirt;
            }
        }
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .data_size = options.data_size,
            .queue_size = options.queue_size,
            .clients = std.ArrayList(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt_rx = options.virt_rx,
            .virt_tx = virt_tx,
            .enable_color = options.enable_color,

            .driver_config = std.mem.zeroInit(ConfigResources.Serial.Driver, .{}),
            .virt_rx_config = std.mem.zeroInit(ConfigResources.Serial.VirtRx, .{}),
            .virt_tx_config = std.mem.zeroInit(ConfigResources.Serial.VirtTx, .{}),
            .client_configs = std.ArrayList(ConfigResources.Serial.Client).init(allocator),
        };
    }

    pub fn deinit(system: *Serial) void {
        system.clients.deinit();
        system.client_configs.deinit();
    }

    pub fn addClient(system: *Serial, client: *Pd) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        system.clients.append(client) catch @panic("Could not add client to Serial");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Serial.Client, .{})) catch @panic("Could not add client to Serial");
    }

    fn hasRx(system: *Serial) bool {
        return system.virt_rx != null;
    }

    fn createConnection(system: *Serial, server: *Pd, client: *Pd, server_conn: *ConfigResources.Serial.Connection, client_conn: *ConfigResources.Serial.Connection) void {
        const queue_mr_name = fmt(system.allocator, "{s}/serial/queue/{s}/{s}", .{ system.device.name, server.name, client.name });
        const queue_mr = Mr.create(system.allocator, queue_mr_name, system.queue_size, .{});
        system.sdf.addMemoryRegion(queue_mr);

        const queue_mr_server_map = Map.create(queue_mr, server.getMapVaddr(&queue_mr), .rw, .{});
        server.addMap(queue_mr_server_map);
        server_conn.queue = .createFromMap(queue_mr_server_map);

        const queue_mr_client_map = Map.create(queue_mr, client.getMapVaddr(&queue_mr), .rw, .{});
        client.addMap(queue_mr_client_map);
        client_conn.queue = .createFromMap(queue_mr_client_map);

        const data_mr_name = fmt(system.allocator, "{s}/serial/data/{s}/{s}", .{ system.device.name, server.name, client.name });
        const data_mr = Mr.create(system.allocator, data_mr_name, system.data_size, .{});
        system.sdf.addMemoryRegion(data_mr);

        // TOOD: the permissions are incorrect, virtualisers should not have write access to the data
        const data_mr_server_map = Map.create(data_mr, server.getMapVaddr(&data_mr), .rw, .{});
        server.addMap(data_mr_server_map);
        server_conn.data = .createFromMap(data_mr_server_map);

        const data_mr_client_map = Map.create(data_mr, client.getMapVaddr(&data_mr), .rw, .{});
        client.addMap(data_mr_client_map);
        client_conn.data = .createFromMap(data_mr_client_map);

        const channel = Channel.create(server, client, .{}) catch unreachable;
        system.sdf.addChannel(channel);
        server_conn.id = channel.pd_a_id;
        client_conn.id = channel.pd_b_id;
    }

    pub fn connect(system: *Serial) !void {
        try createDriver(system.sdf, system.driver, system.device, .serial, &system.device_res);

        system.driver_config.default_baud = 115200;

        if (system.hasRx()) {
            system.createConnection(system.driver, system.virt_rx.?, &system.driver_config.rx, &system.virt_rx_config.driver);

            system.virt_rx_config.num_clients = @intCast(system.clients.items.len);
            for (system.clients.items, 0..) |client, i| {
                system.createConnection(system.virt_rx.?, client, &system.virt_rx_config.clients[i], &system.client_configs.items[i].rx);
            }

            system.driver_config.rx_enabled = 1;

            system.virt_rx_config.switch_char = 28;
            system.virt_rx_config.terminate_num_char = '\r';

            system.virt_tx_config.enable_rx = 1;
        }

        system.createConnection(system.driver, system.virt_tx, &system.driver_config.tx, &system.virt_tx_config.driver);

        system.virt_tx_config.num_clients = @intCast(system.clients.items.len);
        for (system.clients.items, 0..) |client, i| {
            // assuming name is null-terminated
            @memcpy(system.virt_tx_config.clients[i].name[0..client.name.len], client.name);
            assert(client.name.len < ConfigResources.Serial.VirtTx.MAX_NAME_LEN);
            assert(system.virt_tx_config.clients[i].name[client.name.len] == 0);

            system.createConnection(system.virt_tx, client, &system.virt_tx_config.clients[i].conn, &system.client_configs.items[i].tx);
        }

        system.virt_tx_config.enable_colour = @intFromBool(system.enable_color);

        const begin_str = "Begin input\n";
        @memcpy(system.virt_tx_config.begin_str[0..begin_str.len], begin_str);
        assert(system.virt_tx_config.begin_str[begin_str.len] == 0);

        system.virt_tx_config.begin_str_len = begin_str.len;

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Serial, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.driver_config, prefix, "serial_driver_config");
        try data.serialize(allocator, system.virt_rx_config, prefix, "serial_virt_rx");
        try data.serialize(allocator, system.virt_tx_config, prefix, "serial_virt_tx");

        for (system.clients.items, 0..) |client, i| {
            const data_name = fmt(allocator, "serial_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, data_name);
        }

        system.serialised = true;
    }
};

pub const Net = struct {
    const BUFFER_SIZE = 2048;

    pub const Error = SystemError || error{
        InvalidClient,
        DuplicateCopier,
        DuplicateMacAddr,
        InvalidMacAddr,
    };

    pub const Options = struct {
        rx_buffers: usize = 512,
    };

    pub const ClientOptions = struct {
        rx_buffers: usize = 512,
        tx_buffers: usize = 512,
        mac_addr: ?[]const u8 = null,
    };

    pub const ClientInfo = struct {
        rx_buffers: usize = 512,
        tx_buffers: usize = 512,
        mac_addr: ?[6]u8 = null,
    };

    allocator: Allocator,
    sdf: *SystemDescription,
    device: *dtb.Node,

    driver: *Pd,
    virt_rx: *Pd,
    virt_tx: *Pd,
    copiers: std.ArrayList(*Pd),
    clients: std.ArrayList(*Pd),

    device_res: ConfigResources.Device,
    driver_config: ConfigResources.Net.Driver,
    virt_rx_config: ConfigResources.Net.VirtRx,
    virt_tx_config: ConfigResources.Net.VirtTx,
    copy_configs: std.ArrayList(ConfigResources.Net.Copy),
    client_configs: std.ArrayList(ConfigResources.Net.Client),

    connected: bool = false,
    serialised: bool = false,

    rx_buffers: usize,
    client_info: std.ArrayList(ClientInfo),

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd, virt_tx: *Pd, virt_rx: *Pd, options: Options) Net {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = std.ArrayList(*Pd).init(allocator),
            .copiers = std.ArrayList(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt_rx = virt_rx,
            .virt_tx = virt_tx,

            .driver_config = std.mem.zeroInit(ConfigResources.Net.Driver, .{}),
            .virt_rx_config = std.mem.zeroInit(ConfigResources.Net.VirtRx, .{}),
            .virt_tx_config = std.mem.zeroInit(ConfigResources.Net.VirtTx, .{}),
            .copy_configs = std.ArrayList(ConfigResources.Net.Copy).init(allocator),
            .client_configs = std.ArrayList(ConfigResources.Net.Client).init(allocator),

            .client_info = std.ArrayList(ClientInfo).init(allocator),
            .rx_buffers = options.rx_buffers,
        };
    }

    pub fn deinit(system: *Net) void {
        system.copiers.deinit();
        system.clients.deinit();
        system.copy_configs.deinit();
        system.client_configs.deinit();
        system.client_info.deinit();
    }

    fn parseMacAddr(mac_str: []const u8) ![6]u8 {
        var mac_arr = std.mem.zeroes([6]u8);
        var it = std.mem.splitScalar(u8, mac_str, ':');
        for (0..6) |i| {
            mac_arr[i] = try std.fmt.parseInt(u8, it.next().?, 16);
        }
        return mac_arr;
    }

    pub fn addClientWithCopier(system: *Net, client: *Pd, copier: *Pd, options: ClientOptions) Error!void {
        const client_idx = system.clients.items.len;

        // Check that the MAC address isn't present already
        if (options.mac_addr) |a| {
            for (0..client_idx) |i| {
                if (system.client_info.items[i].mac_addr) |b| {
                    if (std.mem.eql(u8, a, &b)) {
                        return Error.DuplicateMacAddr;
                    }
                }
            }
        }
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        // Check that the copier does not already exist
        for (system.copiers.items) |existing_copier| {
            if (std.mem.eql(u8, existing_copier.name, copier.name)) {
                return Error.DuplicateCopier;
            }
        }

        system.clients.append(client) catch @panic("Could not add client with copier to Net");
        system.copiers.append(copier) catch @panic("Could not add client with copier to Net");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Net.Client, .{})) catch @panic("Could not add client with copier to Net");
        system.copy_configs.append(std.mem.zeroInit(ConfigResources.Net.Copy, .{})) catch @panic("Could not add client with copier to Net");

        system.client_info.append(std.mem.zeroInit(ClientInfo, .{})) catch @panic("Could not add client with copier to Net");
        if (options.mac_addr) |mac_addr| {
            system.client_info.items[client_idx].mac_addr = parseMacAddr(mac_addr) catch {
                std.log.err("invalid MAC address given for client '{s}': '{s}'", .{ client.name, mac_addr });
                return Error.InvalidMacAddr;
            };
        }
        system.client_info.items[client_idx].rx_buffers = options.rx_buffers;
        system.client_info.items[client_idx].tx_buffers = options.tx_buffers;
    }

    fn createConnection(system: *Net, server: *Pd, client: *Pd, server_conn: *ConfigResources.Net.Connection, client_conn: *ConfigResources.Net.Connection, num_buffers: u64) void {
        const queue_mr_size = system.sdf.arch.roundToPage(8 + 16 * num_buffers);

        server_conn.num_buffers = @intCast(num_buffers);
        client_conn.num_buffers = @intCast(num_buffers);

        const free_mr_name = fmt(system.allocator, "{s}/net/queue/{s}/{s}/free", .{ system.device.name, server.name, client.name });
        const free_mr = Mr.create(system.allocator, free_mr_name, queue_mr_size, .{});
        system.sdf.addMemoryRegion(free_mr);

        const free_mr_server_map = Map.create(free_mr, server.getMapVaddr(&free_mr), .rw, .{});
        server.addMap(free_mr_server_map);
        server_conn.free_queue = .createFromMap(free_mr_server_map);

        const free_mr_client_map = Map.create(free_mr, client.getMapVaddr(&free_mr), .rw, .{});
        client.addMap(free_mr_client_map);
        client_conn.free_queue = .createFromMap(free_mr_client_map);

        const active_mr_name = fmt(system.allocator, "{s}/net/queue/{s}/{s}/active", .{ system.device.name, server.name, client.name });
        const active_mr = Mr.create(system.allocator, active_mr_name, queue_mr_size, .{});
        system.sdf.addMemoryRegion(active_mr);

        const active_mr_server_map = Map.create(active_mr, server.getMapVaddr(&active_mr), .rw, .{});
        server.addMap(active_mr_server_map);
        server_conn.active_queue = .createFromMap(active_mr_server_map);

        const active_mr_client_map = Map.create(active_mr, client.getMapVaddr(&active_mr), .rw, .{});
        client.addMap(active_mr_client_map);
        client_conn.active_queue = .createFromMap(active_mr_client_map);

        const channel = Channel.create(server, client, .{}) catch @panic("failed to create connection channel");
        system.sdf.addChannel(channel);
        server_conn.id = channel.pd_a_id;
        client_conn.id = channel.pd_b_id;
    }

    fn rxConnectDriver(system: *Net) Mr {
        system.createConnection(system.driver, system.virt_rx, &system.driver_config.virt_rx, &system.virt_rx_config.driver, system.rx_buffers);

        const rx_dma_mr_name = fmt(system.allocator, "{s}/net/rx/data/device", .{system.device.name});
        const rx_dma_mr_size = system.sdf.arch.roundToPage(system.rx_buffers * BUFFER_SIZE);
        const rx_dma_mr = Mr.physical(system.allocator, system.sdf, rx_dma_mr_name, rx_dma_mr_size, .{});
        system.sdf.addMemoryRegion(rx_dma_mr);
        const rx_dma_virt_map = Map.create(rx_dma_mr, system.virt_rx.getMapVaddr(&rx_dma_mr), .r, .{});
        system.virt_rx.addMap(rx_dma_virt_map);
        system.virt_rx_config.data_region = .createFromMap(rx_dma_virt_map);

        const virt_rx_metadata_mr_name = fmt(system.allocator, "{s}/net/rx/virt_metadata", .{system.device.name});
        const virt_rx_metadata_mr_size = system.sdf.arch.roundToPage(system.rx_buffers * 4);
        const virt_rx_metadata_mr = Mr.create(system.allocator, virt_rx_metadata_mr_name, virt_rx_metadata_mr_size, .{});
        system.sdf.addMemoryRegion(virt_rx_metadata_mr);
        const virt_rx_metadata_map = Map.create(virt_rx_metadata_mr, system.virt_rx.getMapVaddr(&virt_rx_metadata_mr), .rw, .{});
        system.virt_rx.addMap(virt_rx_metadata_map);
        system.virt_rx_config.buffer_metadata = .createFromMap(virt_rx_metadata_map);

        return rx_dma_mr;
    }

    fn txConnectDriver(system: *Net) void {
        var num_buffers: usize = 0;
        for (system.client_info.items) |client_info| {
            num_buffers += client_info.tx_buffers;
        }

        system.createConnection(system.driver, system.virt_tx, &system.driver_config.virt_tx, &system.virt_tx_config.driver, num_buffers);
    }

    fn clientRxConnect(system: *Net, rx_dma: Mr, client_idx: usize) void {
        const client_info = system.client_info.items[client_idx];
        const client = system.clients.items[client_idx];
        const copier = system.copiers.items[client_idx];
        var client_config = &system.client_configs.items[client_idx];
        var copier_config = &system.copy_configs.items[client_idx];
        var virt_client_config = &system.virt_rx_config.clients[client_idx];

        system.createConnection(system.virt_rx, copier, &virt_client_config.conn, &copier_config.virt_rx, system.rx_buffers);
        system.createConnection(copier, client, &copier_config.client, &client_config.rx, client_info.rx_buffers);

        const rx_dma_copier_map = Map.create(rx_dma, copier.getMapVaddr(&rx_dma), .rw, .{});
        copier.addMap(rx_dma_copier_map);
        copier_config.device_data = .createFromMap(rx_dma_copier_map);

        const client_data_mr_size = system.sdf.arch.roundToPage(system.rx_buffers * BUFFER_SIZE);
        const client_data_mr_name = fmt(system.allocator, "{s}/net/rx/data/client/{s}", .{ system.device.name, client.name });
        const client_data_mr = Mr.create(system.allocator, client_data_mr_name, client_data_mr_size, .{});
        system.sdf.addMemoryRegion(client_data_mr);

        const client_data_client_map = Map.create(client_data_mr, client.getMapVaddr(&client_data_mr), .rw, .{});
        client.addMap(client_data_client_map);
        client_config.rx_data = .createFromMap(client_data_client_map);

        const client_data_copier_map = Map.create(client_data_mr, copier.getMapVaddr(&client_data_mr), .rw, .{});
        copier.addMap(client_data_copier_map);
        copier_config.client_data = .createFromMap(client_data_copier_map);
    }

    fn clientTxConnect(system: *Net, client_id: usize) void {
        const client_info = &system.client_info.items[client_id];
        const client = system.clients.items[client_id];
        var client_config = &system.client_configs.items[client_id];
        const virt_client_config = &system.virt_tx_config.clients[client_id];

        system.createConnection(system.virt_tx, client, &virt_client_config.conn, &client_config.tx, client_info.tx_buffers);

        const data_mr_size = system.sdf.arch.roundToPage(client_info.tx_buffers * BUFFER_SIZE);
        const data_mr_name = fmt(system.allocator, "{s}/net/tx/data/client/{s}", .{ system.device.name, client.name });
        const data_mr = Mr.physical(system.allocator, system.sdf, data_mr_name, data_mr_size, .{});
        system.sdf.addMemoryRegion(data_mr);

        const data_mr_virt_map = Map.create(data_mr, system.virt_tx.getMapVaddr(&data_mr), .r, .{});
        system.virt_tx.addMap(data_mr_virt_map);
        virt_client_config.data = .createFromMap(data_mr_virt_map);

        const data_mr_client_map = Map.create(data_mr, client.getMapVaddr(&data_mr), .rw, .{});
        client.addMap(data_mr_client_map);
        client_config.tx_data = .createFromMap(data_mr_client_map);
    }

    pub fn generateMacAddrs(system: *Net) void {
        const rand = std.crypto.random;
        for (system.clients.items, 0..) |_, i| {
            if (system.client_info.items[i].mac_addr == null) {
                var mac_addr: [6]u8 = undefined;
                while (true) {
                    rand.bytes(&mac_addr);
                    var unique = true;
                    for (0..i) |j| {
                        const b = system.client_info.items[j].mac_addr.?;
                        if (std.mem.eql(u8, &mac_addr, &b)) {
                            unique = false;
                        }
                    }
                    if (unique) {
                        break;
                    }
                }
                system.client_info.items[i].mac_addr = mac_addr;
            }
        }
    }

    pub fn connect(system: *Net) !void {
        try createDriver(system.sdf, system.driver, system.device, .network, &system.device_res);

        const rx_dma_mr = system.rxConnectDriver();
        system.txConnectDriver();

        system.generateMacAddrs();

        system.virt_tx_config.num_clients = @intCast(system.clients.items.len);
        system.virt_rx_config.num_clients = @intCast(system.clients.items.len);
        for (system.clients.items, 0..) |_, i| {
            // TODO: we have an assumption that all copiers are RX copiers
            system.clientRxConnect(rx_dma_mr, i);
            system.clientTxConnect(i);

            system.virt_rx_config.clients[i].mac_addr = system.client_info.items[i].mac_addr.?;
            system.client_configs.items[i].mac_addr = system.client_info.items[i].mac_addr.?;
        }

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Net, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.driver_config, prefix, "net_driver");
        try data.serialize(allocator, system.virt_rx_config, prefix, "net_virt_rx");
        try data.serialize(allocator, system.virt_tx_config, prefix, "net_virt_tx");

        for (system.copiers.items, 0..) |copier, i| {
            const data_name = fmt(allocator, "net_copy_{s}", .{copier.name});
            try data.serialize(allocator, system.copy_configs.items[i], prefix, data_name);
        }

        for (system.clients.items, 0..) |client, i| {
            const data_name = fmt(allocator, "net_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, data_name);
        }

        system.serialised = true;
    }
};

pub const Gpu = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.ArrayList(*Pd),
    connected: bool = false,
    serialised: bool = false,
    config: Gpu.Config,
    // Configurable parameters. Right now we just hard-code
    // these.
    data_region_size: usize = 2 * 1024 * 1024,
    queue_region_size: usize = 2 * 1024 * 1024,
    // TODO: this should be per-client
    queue_capacity: u16 = 1024,

    const Config = struct {
        driver: ConfigResources.Gpu.Driver = undefined,
        virt_driver: ConfigResources.Gpu.Virt.Driver = undefined,
        virt_clients: std.ArrayList(ConfigResources.Gpu.Virt.Client),
        clients: std.ArrayList(ConfigResources.Gpu.Client),
    };

    pub const Error = SystemError;

    pub const Options = struct {};

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd, virt: *Pd, _: Options) Gpu {
        if (std.mem.eql(u8, driver.name, virt.name)) {
            @panic("TODO");
        }
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = std.ArrayList(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt = virt,
            .config = .{
                .virt_clients = .init(allocator),
                .clients = .init(allocator),
            },
        };
    }

    pub fn deinit(system: *Gpu) void {
        system.clients.deinit();
        system.config.virt_clients.deinit();
        system.config.clients.deinit();
    }

    pub fn addClient(system: *Gpu, client: *Pd) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        system.clients.append(client) catch @panic("Could not add client to Gpu");
    }

    pub fn connectDriver(system: *Gpu) void {
        const sdf = system.sdf;
        const allocator = system.allocator;
        const driver = system.driver;
        const virt = system.virt;

        const mr_events = Mr.create(allocator, "gpu_driver_events", system.queue_region_size, .{});
        const map_events_driver = Map.create(mr_events, driver.getMapVaddr(&mr_events), .rw, .{});
        const map_events_virt = Map.create(mr_events, virt.getMapVaddr(&mr_events), .rw, .{});
        sdf.addMemoryRegion(mr_events);
        driver.addMap(map_events_driver);
        virt.addMap(map_events_virt);

        const mr_req = Mr.create(allocator, "gpu_driver_request", system.queue_region_size, .{});
        const map_req_driver = Map.create(mr_req, driver.getMapVaddr(&mr_req), .rw, .{});
        const map_req_virt = Map.create(mr_req, virt.getMapVaddr(&mr_req), .rw, .{});
        sdf.addMemoryRegion(mr_req);
        driver.addMap(map_req_driver);
        virt.addMap(map_req_virt);

        const mr_resp = Mr.create(allocator, "gpu_driver_response", system.queue_region_size, .{});
        const map_resp_driver = Map.create(mr_resp, driver.getMapVaddr(&mr_resp), .rw, .{});
        const map_resp_virt = Map.create(mr_resp, virt.getMapVaddr(&mr_resp), .rw, .{});
        sdf.addMemoryRegion(mr_resp);
        driver.addMap(map_resp_driver);
        virt.addMap(map_resp_virt);

        const mr_data = Mr.physical(allocator, sdf, "gpu_driver_data", system.data_region_size, .{});
        const map_data_driver = Map.create(mr_data, driver.getMapVaddr(&mr_data), .rw, .{});
        const map_data_virt = Map.create(mr_data, virt.getMapVaddr(&mr_data), .rw, .{});
        sdf.addMemoryRegion(mr_data);
        driver.addMap(map_data_driver);
        virt.addMap(map_data_virt);

        const ch = Channel.create(system.virt, system.driver, .{}) catch unreachable;
        system.sdf.addChannel(ch);

        system.config.driver = .{
            .virt = .{
                .events = .createFromMap(map_events_driver),
                .req_queue = .createFromMap(map_req_driver),
                .resp_queue = .createFromMap(map_resp_driver),
                .num_buffers = system.queue_capacity,
                .id = ch.pd_b_id,
            },
            .data = .createFromMap(map_data_driver),
        };

        system.config.virt_driver = .{
            .conn = .{
                .events = .createFromMap(map_events_virt),
                .req_queue = .createFromMap(map_req_virt),
                .resp_queue = .createFromMap(map_resp_virt),
                .num_buffers = system.queue_capacity,
                .id = ch.pd_a_id,
            },
            .data = .createFromMap(map_data_virt),
        };
    }

    pub fn connectClient(system: *Gpu, client: *Pd) void {
        const sdf = system.sdf;
        const allocator = system.allocator;

        const mr_events = Mr.create(allocator, fmt(allocator, "gpu_client_{s}_events", .{client.name}), system.queue_region_size, .{});
        const map_events_virt = Map.create(mr_events, system.virt.getMapVaddr(&mr_events), .rw, .{});
        const map_events_client = Map.create(mr_events, client.getMapVaddr(&mr_events), .r, .{});
        system.sdf.addMemoryRegion(mr_events);
        system.virt.addMap(map_events_virt);
        client.addMap(map_events_client);

        const mr_req = Mr.create(allocator, fmt(allocator, "gpu_client_{s}_request", .{client.name}), system.queue_region_size, .{});
        const map_req_virt = Map.create(mr_req, system.virt.getMapVaddr(&mr_req), .rw, .{});
        const map_req_client = Map.create(mr_req, client.getMapVaddr(&mr_req), .rw, .{});
        system.sdf.addMemoryRegion(mr_req);
        system.virt.addMap(map_req_virt);
        client.addMap(map_req_client);

        const mr_resp = Mr.create(allocator, fmt(allocator, "gpu_client_{s}_response", .{client.name}), system.queue_region_size, .{});
        const map_resp_virt = Map.create(mr_resp, system.virt.getMapVaddr(&mr_resp), .rw, .{});
        const map_resp_client = Map.create(mr_resp, client.getMapVaddr(&mr_resp), .rw, .{});
        system.sdf.addMemoryRegion(mr_resp);
        system.virt.addMap(map_resp_virt);
        client.addMap(map_resp_client);

        const mr_data = Mr.physical(allocator, sdf, fmt(allocator, "gpu_client_{s}_data", .{client.name}), system.data_region_size, .{});
        const map_data_virt = Map.create(mr_data, system.virt.getMapVaddr(&mr_data), .rw, .{});
        const map_data_client = Map.create(mr_data, client.getMapVaddr(&mr_data), .rw, .{});
        system.sdf.addMemoryRegion(mr_data);
        system.virt.addMap(map_data_virt);
        client.addMap(map_data_client);

        const ch = Channel.create(system.virt, client, .{}) catch unreachable;
        system.sdf.addChannel(ch);

        system.config.virt_clients.append(.{
            .conn = .{
                .events = .createFromMap(map_events_virt),
                .req_queue = .createFromMap(map_req_virt),
                .resp_queue = .createFromMap(map_resp_virt),
                .num_buffers = system.queue_capacity,
                .id = ch.pd_a_id,
            },
            .data = .createFromMap(map_data_virt),
        }) catch @panic("could not add virt client config");

        system.config.clients.append(.{ .virt = .{
            .events = .createFromMap(map_events_client),
            .req_queue = .createFromMap(map_req_client),
            .resp_queue = .createFromMap(map_resp_client),
            .num_buffers = system.queue_capacity,
            .id = ch.pd_b_id,
        }, .data = .createFromMap(map_data_client) }) catch @panic("could not add client config");
    }

    pub fn connect(system: *Gpu) !void {
        const sdf = system.sdf;

        // 1. Create the device resources for the driver
        try createDriver(sdf, system.driver, system.device, .gpu, &system.device_res);
        // 2. Connect the driver to the virtualiser
        system.connectDriver();
        // 3. Connect each client to the virtualiser
        for (system.clients.items) |client| {
            system.connectClient(client);
        }

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Gpu, prefix: []const u8) !void {
        if (!system.connected) return error.SystemNotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(system.allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.config.driver, prefix, "gpu_driver");

        const virt_config = ConfigResources.Gpu.Virt.create(system.config.virt_driver, system.config.virt_clients.items);
        try data.serialize(allocator, virt_config, prefix, "gpu_virt");

        for (system.config.clients.items, 0..) |config, i| {
            const client_data = fmt(allocator, "gpu_client_{s}", .{system.clients.items[i].name});
            try data.serialize(allocator, config, prefix, client_data);
        }

        system.serialised = true;
    }
};

pub const Lwip = struct {
    const PBUF_STRUCT_SIZE = 56;

    allocator: Allocator,
    sdf: *SystemDescription,
    net: *Net,
    pd: *Pd,
    num_pbufs: usize,

    config: ConfigResources.Lib.SddfLwip,

    pub fn init(allocator: Allocator, sdf: *SystemDescription, net: *Net, pd: *Pd) Lwip {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .net = net,
            .pd = pd,
            .num_pbufs = net.rx_buffers * 2,
            .config = std.mem.zeroInit(ConfigResources.Lib.SddfLwip, .{}),
        };
    }

    pub fn connect(lib: *Lwip) !void {
        const pbuf_pool_mr_size = lib.num_pbufs * PBUF_STRUCT_SIZE;
        const pbuf_pool_mr_name = fmt(lib.allocator, "{s}/net/lib_sddf_lwip/{s}", .{ lib.net.device.name, lib.pd.name });
        const pbuf_pool_mr = Mr.create(lib.allocator, pbuf_pool_mr_name, pbuf_pool_mr_size, .{});
        lib.sdf.addMemoryRegion(pbuf_pool_mr);

        const pbuf_pool_mr_map = Map.create(pbuf_pool_mr, lib.pd.getMapVaddr(&pbuf_pool_mr), .rw, .{});
        lib.pd.addMap(pbuf_pool_mr_map);
        lib.config.pbuf_pool = .createFromMap(pbuf_pool_mr_map);
        lib.config.num_pbufs = lib.num_pbufs;
    }

    pub fn serialiseConfig(lib: *Lwip, prefix: []const u8) !void {
        const config_data = fmt(lib.allocator, "lib_sddf_lwip_config_{s}", .{lib.pd.name});
        try data.serialize(lib.allocator, lib.config, prefix, config_data);
    }
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
pub fn createDriver(sdf: *SystemDescription, pd: *Pd, device: *dtb.Node, class: Config.Driver.Class, device_res: *ConfigResources.Device) !void {
    if (!probed) return error.CalledBeforeProbe;
    // First thing to do is find the driver configuration for the device given.
    // The way we do that is by searching for the compatible string described in the DTB node.
    const compatible = device.prop(.Compatible).?;

    log.debug("Creating driver for device: '{s}'", .{device.name});
    log.debug("Compatible with:", .{});
    for (compatible) |c| {
        log.debug("     '{s}'", .{c});
    }
    // Get the driver based on the compatible string are given, assuming we can
    // find it.
    const driver = if (findDriver(compatible, class)) |d| d else {
        log.err("Cannot find driver matching '{s}' for class '{s}'", .{ device.name, @tagName(class) });
        return error.UnknownDevice;
    };
    log.debug("Found compatible driver '{s}'", .{driver.dir});

    // If a status property does exist, we should check that it is 'okay'
    if (device.prop(.Status)) |status| {
        if (status != .Okay) {
            log.err("Device '{s}' has invalid status: '{s}'", .{ device.name, status });
            return error.DeviceStatusInvalid;
        }
    }

    for (driver.resources.regions) |region_resource| {
        // TODO: all this error checking should be done when we parse config.json
        if (region_resource.dt_index == null and region_resource.size == null) {
            log.err("driver '{s}' has region resource '{s}'' which specifies neither dt_index nor size: one or both must be specified", .{ driver.dir, region_resource.name });
        }

        if (region_resource.dt_index != null and region_resource.cached != null and region_resource.cached.? == true) {
            log.err("driver '{s}' has region resource '{s}' which tries to map MMIO region as cached", .{ driver.dir, region_resource.name });
        }

        const mr_name = fmt(sdf.allocator, "{s}/{s}/{s}", .{ device.name, driver.dir, region_resource.name });

        var mr: ?Mr = null;
        var device_reg_offset: u64 = 0;
        if (region_resource.dt_index != null) {
            const dt_reg = device.prop(.Reg).?;
            assert(region_resource.dt_index.? < dt_reg.len);

            const dt_reg_entry = dt_reg[region_resource.dt_index.?];
            const dt_reg_paddr = dt_reg_entry[0];
            const dt_reg_size = sdf.arch.roundToPage(@intCast(dt_reg_entry[1]));

            if (region_resource.size != null and dt_reg_size < region_resource.size.?) {
                log.err("device '{s}' has config region size for dt_index '{?}' that is too small (0x{x} bytes)", .{ device.name, region_resource.dt_index, dt_reg_size });
                return error.InvalidConfig;
            }

            if (region_resource.size != null and region_resource.size.? & (sdf.arch.defaultPageSize() - 1) != 0) {
                log.err("device '{s}' has config region size not aligned to page size for dt_index '{?}'", .{ device.name, region_resource.dt_index });
                return error.InvalidConfig;
            }

            if (dt_reg_size & ((1 << 12) - 1) != 0) {
                log.err("device '{s}' has DTB region size not aligned to page size for dt_index '{?}'", .{ device.name, region_resource.dt_index });
                return error.InvalidConfig;
            }

            const mr_size = if (region_resource.size != null) region_resource.size.? else dt_reg_size;

            const device_paddr = dtb.regPaddr(sdf.arch, device, @intCast(dt_reg_paddr));
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
        } else {
            const mr_size = region_resource.size.?;
            mr = Mr.physical(sdf.allocator, sdf, mr_name, mr_size, .{});
            sdf.addMemoryRegion(mr.?);
        }

        const perms = blk: {
            if (region_resource.perms) |perms| {
                break :blk Map.Perms.fromString(perms) catch |e| {
                    log.err("failed to create driver '{s}', invalid perms '{s}': {any}", .{ device.name, perms, e });
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

    // For all driver IRQs, find the corresponding entry in the device tree and
    // process it for the SDF.
    const maybe_dt_irqs = device.prop(.Interrupts);
    if (driver.resources.irqs.len != 0 and maybe_dt_irqs == null) {
        log.err("expected interrupts field for node '{s}' when creating driver '{s}'", .{ device.name, driver.dir });
        return error.InvalidDeviceTreeNode;
    }

    for (driver.resources.irqs) |driver_irq| {
        const dt_irqs = maybe_dt_irqs.?;
        if (driver_irq.dt_index >= dt_irqs.len) {
            log.err("invalid device tree index '{}' when creating driver '{s}'", .{ driver_irq.dt_index, driver.dir });
            return error.InvalidDeviceTreeIndex;
        }
        const dt_irq = dt_irqs[driver_irq.dt_index];

        const irq = blk: {
            if (sdf.arch.isArm()) {
                std.debug.assert(dt_irq.len == 3);
                // Determine the IRQ trigger and (software-observable) number based on the device tree.
                const irq_type = dtb.armGicIrqType(dt_irq[0]);
                const irq_number = dtb.armGicIrqNumber(dt_irq[1], irq_type);
                const irq_trigger = dtb.armGicTrigger(dt_irq[2]);

                break :blk SystemDescription.Irq.create(irq_number, .{
                    .trigger = irq_trigger,
                    .id = driver_irq.channel_id,
                });
            } else if (sdf.arch.isRiscv()) {
                std.debug.assert(dt_irq.len == 1);
                const irq_number = dt_irq[0];
                break :blk SystemDescription.Irq.create(irq_number, .{ .id = driver_irq.channel_id });
            } else {
                @panic("device driver IRQ handling is unimplemented for given arch");
            }
        };

        const irq_channel = try pd.addIrq(irq);

        device_res.irqs[device_res.num_irqs] = .{
            .id = irq_channel,
        };
        device_res.num_irqs += 1;
    }
}
