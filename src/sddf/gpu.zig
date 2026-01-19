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

pub const Gpu = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: *dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.array_list.Managed(*Pd),
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
        virt_clients: std.array_list.Managed(ConfigResources.Gpu.Virt.Client),
        clients: std.array_list.Managed(ConfigResources.Gpu.Client),
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
            .clients = std.array_list.Managed(*Pd).init(allocator),
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
        try sddf.createDriver(sdf, system.driver, system.device, null, .gpu, &system.device_res);
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

