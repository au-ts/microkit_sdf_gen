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

pub const I2c = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.array_list.Managed(*Pd),
    region_req_size: usize,
    region_resp_size: usize,
    region_data_size: usize,
    driver_config: ConfigResources.I2c.Driver,
    virt_config: ConfigResources.I2c.Virt,
    client_configs: std.array_list.Managed(ConfigResources.I2c.Client),
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
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt = virt,
            .region_req_size = options.region_req_size,
            .region_resp_size = options.region_resp_size,
            .region_data_size = options.region_data_size,
            .driver_config = std.mem.zeroInit(ConfigResources.I2c.Driver, .{}),
            .virt_config = std.mem.zeroInit(ConfigResources.I2c.Virt, .{}),
            .client_configs = std.array_list.Managed(ConfigResources.I2c.Client).init(allocator),
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
                .req_queue = .createFromMap(driver_map_req),
                .resp_queue = .createFromMap(driver_map_resp),
                .num_buffers = system.num_buffers,
                .id = ch.pd_a_id,
            },
        };

        system.virt_config.driver = .{
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
                .req_queue = .createFromMap(virt_map_req),
                .resp_queue = .createFromMap(virt_map_resp),
                .num_buffers = system.num_buffers,
                .id = ch.pd_a_id,
            },
            .data_size = system.region_data_size,
            .driver_data_vaddr = driver_map_data.vaddr,
            .client_data_vaddr = client_map_data.vaddr,
        };

        system.client_configs.items[i] = .{
            .virt = .{
                .req_queue = .createFromMap(client_map_req),
                .resp_queue = .createFromMap(client_map_resp),
                .num_buffers = system.num_buffers,
                .id = ch.pd_b_id,
            },
            .data = .createFromMap(client_map_data),
        };
    }

    pub fn connect(system: *I2c) !void {
        const sdf = system.sdf;

        // 1. Create the device resources for the driver
        if (system.device) |device| {
            try sddf.createDriver(sdf, system.driver, device, .i2c, &system.device_res);
        }
        // 2. Connect the driver to the virtualiser
        system.connectDriver();

        // 3. Connect each client to the virtualiser
        for (system.clients.items, 0..) |client, i| {
            system.connectClient(client, i);
        }

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
