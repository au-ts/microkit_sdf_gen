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

// TODO: probably make all queue_capacity/num_buffers u32
pub const Blk = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.array_list.Managed(Client),
    connected: bool = false,
    serialised: bool = false,
    // Only needed for initialisation to read partition table, maximum of 10 pages
    // for either MBR or GPT
    driver_data_size: u32 = 10 * 0x1000,
    config: Blk.Config,

    const Client = struct {
        pd: *Pd,
        partition: u32,
        queue_capacity: u16,
        data_size: u32,
    };

    const Config = struct {
        driver: ConfigResources.Blk.Driver = undefined,
        virt_driver: ConfigResources.Blk.Virt.Driver = undefined,
        virt_clients: std.array_list.Managed(ConfigResources.Blk.Virt.Client),
        clients: std.array_list.Managed(ConfigResources.Blk.Client),
    };

    pub const Error = SystemError || error{
        InvalidVirt,
    };

    pub const Options = struct {};

    const STORAGE_INFO_REGION_SIZE: usize = 0x1000;

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd, virt: *Pd, _: Options) Error!Blk {
        if (std.mem.eql(u8, driver.name, virt.name)) {
            log.err("invalid blk virtualiser, same name as driver '{s}", .{virt.name});
            return Error.InvalidVirt;
        }
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = std.array_list.Managed(Client).init(allocator),
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
        system.config.virt_clients.deinit();
        system.config.clients.deinit();
    }

    // TODO: need to do more error checking on data size and queue capacity.
    pub const ClientOptions = struct {
        // Zero-index of device partition to use.
        partition: u32,
        // Maximum possible entries in a single queue.
        queue_capacity: u16 = 128,
        // Default to 2MB.
        data_size: u32 = 2 * 1024 * 1024,
    };

    pub fn addClient(system: *Blk, client: *Pd, options: ClientOptions) Error!void {
        // Check that the client does not already exist
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.pd.name, client.name)) {
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
        system.clients.append(.{
            .pd = client,
            .partition = options.partition,
            .queue_capacity = options.queue_capacity,
            .data_size = options.data_size,
        }) catch @panic("Could not add client to Blk");
    }

    fn driverQueueCapacity(system: *Blk) u16 {
        var total_capacity: u16 = 0;
        for (system.clients.items) |client| {
            total_capacity += client.queue_capacity;
        }

        return total_capacity;
    }

    fn driverQueueMrSize(system: *Blk) u32 {
        // TODO: 128 bytes is enough for each queue entry, but need to be
        // better about how this is determined.
        return @as(u32, driverQueueCapacity(system)) * @as(u32, 128);
    }

    pub fn connectDriver(system: *Blk) void {
        const sdf = system.sdf;
        const allocator = system.allocator;
        const driver = system.driver;
        const virt = system.virt;
        const queue_mr_size = driverQueueMrSize(system);
        const queue_capacity = driverQueueCapacity(system);

        const mr_storage_info = Mr.create(allocator, "blk_driver_storage_info", STORAGE_INFO_REGION_SIZE, .{});
        const map_storage_info_driver = Map.create(mr_storage_info, system.driver.getMapVaddr(&mr_storage_info), .rw, .{});
        const map_storage_info_virt = Map.create(mr_storage_info, system.virt.getMapVaddr(&mr_storage_info), .r, .{});

        sdf.addMemoryRegion(mr_storage_info);
        driver.addMap(map_storage_info_driver);
        virt.addMap(map_storage_info_virt);

        const mr_req = Mr.create(allocator, "blk_driver_request", queue_mr_size, .{});
        const map_req_driver = Map.create(mr_req, driver.getMapVaddr(&mr_req), .rw, .{});
        const map_req_virt = Map.create(mr_req, virt.getMapVaddr(&mr_req), .rw, .{});

        sdf.addMemoryRegion(mr_req);
        driver.addMap(map_req_driver);
        virt.addMap(map_req_virt);

        const mr_resp = Mr.create(allocator, "blk_driver_response", queue_mr_size, .{});
        const map_resp_driver = Map.create(mr_resp, driver.getMapVaddr(&mr_resp), .rw, .{});
        const map_resp_virt = Map.create(mr_resp, virt.getMapVaddr(&mr_resp), .rw, .{});

        sdf.addMemoryRegion(mr_resp);
        driver.addMap(map_resp_driver);
        virt.addMap(map_resp_virt);

        const mr_data = Mr.physical(allocator, sdf, "blk_driver_data", system.driver_data_size, .{});
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
                .num_buffers = queue_capacity,
                .id = ch.pd_b_id,
            },
        };

        system.config.virt_driver = .{
            .conn = .{
                .storage_info = .createFromMap(map_storage_info_virt),
                .req_queue = .createFromMap(map_req_virt),
                .resp_queue = .createFromMap(map_resp_virt),
                .num_buffers = queue_capacity,
                .id = ch.pd_a_id,
            },
            .data = .createFromMap(map_data_virt),
        };
    }

    pub fn connectClient(system: *Blk, client: *Client, i: usize) void {
        const sdf = system.sdf;
        const allocator = system.allocator;
        const queue_mr_size: u32 = @as(u32, client.queue_capacity) * @as(u32, 128);
        const data_mr_size = client.data_size;
        const client_pd = client.pd;

        const mr_storage_info = Mr.create(allocator, fmt(allocator, "blk_client_{s}_storage_info", .{client_pd.name}), STORAGE_INFO_REGION_SIZE, .{});
        const map_storage_info_virt = Map.create(mr_storage_info, system.virt.getMapVaddr(&mr_storage_info), .rw, .{});
        const map_storage_info_client = Map.create(mr_storage_info, client_pd.getMapVaddr(&mr_storage_info), .r, .{});

        system.sdf.addMemoryRegion(mr_storage_info);
        system.virt.addMap(map_storage_info_virt);
        client_pd.addMap(map_storage_info_client);

        const mr_req = Mr.create(allocator, fmt(allocator, "blk_client_{s}_request", .{client_pd.name}), queue_mr_size, .{});
        const map_req_virt = Map.create(mr_req, system.virt.getMapVaddr(&mr_req), .rw, .{});
        const map_req_client = Map.create(mr_req, client_pd.getMapVaddr(&mr_req), .rw, .{});

        system.sdf.addMemoryRegion(mr_req);
        system.virt.addMap(map_req_virt);
        client_pd.addMap(map_req_client);

        const mr_resp = Mr.create(allocator, fmt(allocator, "blk_client_{s}_response", .{client_pd.name}), queue_mr_size, .{});
        const map_resp_virt = Map.create(mr_resp, system.virt.getMapVaddr(&mr_resp), .rw, .{});
        const map_resp_client = Map.create(mr_resp, client_pd.getMapVaddr(&mr_resp), .rw, .{});

        system.sdf.addMemoryRegion(mr_resp);
        system.virt.addMap(map_resp_virt);
        client_pd.addMap(map_resp_client);

        const mr_data = Mr.physical(allocator, sdf, fmt(allocator, "blk_client_{s}_data", .{client_pd.name}), data_mr_size, .{});
        const map_data_virt = Map.create(mr_data, system.virt.getMapVaddr(&mr_data), .rw, .{});
        const map_data_client = Map.create(mr_data, client_pd.getMapVaddr(&mr_data), .rw, .{});

        system.sdf.addMemoryRegion(mr_data);
        system.virt.addMap(map_data_virt);
        client_pd.addMap(map_data_client);

        const ch = Channel.create(system.virt, client_pd, .{}) catch unreachable;
        system.sdf.addChannel(ch);

        system.config.virt_clients.append(.{
            .conn = .{
                .storage_info = .createFromMap(map_storage_info_virt),
                .req_queue = .createFromMap(map_req_virt),
                .resp_queue = .createFromMap(map_resp_virt),
                .num_buffers = client.queue_capacity,
                .id = ch.pd_a_id,
            },
            .data = .createFromMap(map_data_virt),
            .partition = system.clients.items[i].partition,
        }) catch @panic("could not add virt client config");

        system.config.clients.append(.{ .virt = .{
            .storage_info = .createFromMap(map_storage_info_client),
            .req_queue = .createFromMap(map_req_client),
            .resp_queue = .createFromMap(map_resp_client),
            .num_buffers = client.queue_capacity,
            .id = ch.pd_b_id,
        }, .data = .createFromMap(map_data_client) }) catch @panic("could not add client config");
    }

    pub fn connect(system: *Blk) !void {
        const sdf = system.sdf;

        // 1. Create the device resources for the driver
        if (system.device) |dtb_node| {
            try sddf.createDriver(sdf, system.driver, dtb_node, .blk, &system.device_res);
        }
        // 2. Connect the driver to the virtualiser
        system.connectDriver();
        // 3. Connect each client to the virtualiser
        for (system.clients.items, 0..) |*client, i| {
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
            const client_config = fmt(allocator, "blk_client_{s}", .{system.clients.items[i].pd.name});
            try data.serialize(allocator, config, prefix, client_config);
        }

        system.serialised = true;
    }
};
