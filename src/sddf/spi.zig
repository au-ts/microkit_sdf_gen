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

pub const Spi = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver: *Pd,
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    virt: *Pd,
    clients: std.ArrayList(Client),
    connected: bool = false,
    serialised: bool = false,
    config: Spi.Config,

    const Client = struct {
        pd: *Pd,
        num_prev_occurances: u8,
        cs: u8,
        cpha: bool,
        cpol: bool,
        freq_div: u64,
        queue_capacity: u16,
        data_size: u32,
    };

    const Config = struct {
        driver: ConfigResources.Spi.Driver = undefined,
        virt: ConfigResources.Spi.Virt = undefined,
        clients: std.ArrayList(ConfigResources.Spi.Client),
    };

    // TODO: move this up once config-time queue sizes are generally supported
    pub const Error = SystemError || error {InvalidQueueCapacity};

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd, virt: *Pd) Spi {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = .init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt = virt,
            .config = .{
                .driver = std.mem.zeroInit(ConfigResources.Spi.Driver, .{}),
                .virt = std.mem.zeroInit(ConfigResources.Spi.Virt, .{}),
                .clients = std.ArrayList(ConfigResources.Spi.Client).init(allocator),
            },
        };
    }

    pub fn deinit(system: *Spi) void {
        system.clients.deinit();
        system.config.clients.deinit();
    }

    pub const ClientOptions = struct {
        cs: u8,
        cpha: bool = false,
        cpol: bool = false,
        freq_div: u64 = 0,
        queue_capacity: u16 = 128,
        data_size: u32 = 0x10000,
    };

    pub fn addClient(system: *Spi, client: *Pd, options: ClientOptions) Error!void {
        // Check that the Pd is not a virt or driver
        if (std.mem.eql(u8, client.name, system.driver.name)) {
            log.err("invalid spi client, same name as driver '{s}", .{client.name});
            return Error.InvalidClient;
        }
        if (std.mem.eql(u8, client.name, system.virt.name)) {
            log.err("invalid spi client, same name as virt '{s}", .{client.name});
            return Error.InvalidClient;
        }
        if (options.queue_capacity == 0) {
            log.err("invalid queue capacity, it must be greater than 0", .{});
            return Error.InvalidQueueCapacity;
        }
        // TODO: check if the queue capacity is too large

        if (!std.math.isPowerOfTwo(options.queue_capacity)) {
            log.err("invalid queue capacity, {d} is not a power of two", .{options.queue_capacity});
            return Error.InvalidQueueCapacity;
        }

        var num_prev_occurances: u8 = 0;
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.pd.name, client.name)) {
                num_prev_occurances += 1;
            }
        }
        system.clients.append(.{
            .pd = client,
            .num_prev_occurances = num_prev_occurances,
            .cs = options.cs,
            .cpha = options.cpha,
            .cpol = options.cpol,
            .freq_div = options.freq_div,
            .queue_capacity = options.queue_capacity,
            .data_size = options.data_size,
        }) catch @panic("Could not add client to spi");
        system.config.clients.append(std.mem.zeroInit(ConfigResources.Spi.Client, .{})) catch @panic("Could not add client to spi");
    }

    fn driverQueueCapacity(system: *Spi) u16 {
        var total_capacity: u16 = 0;
        for (system.clients.items) |client| {
            total_capacity += client.queue_capacity;
        }

        return std.math.ceilPowerOfTwoAssert(u16, total_capacity);
    }

    fn driverCmdQueueMrSize(system: *Spi) u64 {
        // TODO: 24 bytes is enough for each queue entry, but need to be
        // better about how this is determined.
        return Arch.roundUpToPage(system.sdf.arch, @as(u64, driverQueueCapacity(system)) * @as(u64, 32));
    }
    fn driverRespQueueMrSize(system: *Spi) u64 {
        // TODO: 4 bytes is enough for each queue entry, but need to be
        // better about how this is determined.
        return Arch.roundUpToPage(system.sdf.arch, @as(u64, driverQueueCapacity(system)) * @as(u64, 4));
    }
    fn driverCsQueueMrSize(system: *Spi) u64 {
        // TODO: 1 byte is enough for each queue entry, but need to be
        // better about how this is determined.
        return Arch.roundUpToPage(system.sdf.arch, @as(u64, driverQueueCapacity(system)));
    }

    pub fn connectDriver(system: *Spi) void {
        const allocator = system.allocator;
        var sdf = system.sdf;
        var driver = system.driver;
        var virt = system.virt;

        // Create all the MRs between the driver and virtualiser
        const mr_cmd = Mr.create(allocator, "spi_driver_cmd", driverCmdQueueMrSize(system), .{});
        const mr_resp = Mr.create(allocator, "spi_driver_resp", driverRespQueueMrSize(system), .{});
        const mr_cmd_cs = Mr.create(allocator, "spi_driver_cmd_cs", driverCsQueueMrSize(system), .{});
        const mr_resp_cs = Mr.create(allocator, "spi_driver_resp_cs", driverCsQueueMrSize(system), .{});

        sdf.addMemoryRegion(mr_cmd);
        sdf.addMemoryRegion(mr_resp);
        sdf.addMemoryRegion(mr_cmd_cs);
        sdf.addMemoryRegion(mr_resp_cs);

        const driver_map_cmd = Map.create(mr_cmd, driver.getMapVaddr(&mr_cmd), .rw, .{});
        driver.addMap(driver_map_cmd);
        const driver_map_resp = Map.create(mr_resp, driver.getMapVaddr(&mr_resp), .rw, .{});
        driver.addMap(driver_map_resp);
        const driver_map_cmd_cs = Map.create(mr_cmd_cs, driver.getMapVaddr(&mr_cmd_cs), .rw, .{});
        driver.addMap(driver_map_cmd_cs);
        const driver_map_resp_cs = Map.create(mr_resp_cs, driver.getMapVaddr(&mr_resp_cs), .rw, .{});
        driver.addMap(driver_map_resp_cs);

        const virt_map_cmd = Map.create(mr_cmd, virt.getMapVaddr(&mr_cmd), .rw, .{});
        virt.addMap(virt_map_cmd);
        const virt_map_resp = Map.create(mr_resp, virt.getMapVaddr(&mr_resp), .rw, .{});
        virt.addMap(virt_map_resp);
        const virt_map_cmd_cs = Map.create(mr_cmd_cs, virt.getMapVaddr(&mr_cmd_cs), .rw, .{});
        virt.addMap(virt_map_cmd_cs);
        const virt_map_resp_cs = Map.create(mr_resp_cs, virt.getMapVaddr(&mr_resp_cs), .rw, .{});
        virt.addMap(virt_map_resp_cs);

        const ch = Channel.create(system.driver, system.virt, .{}) catch unreachable;
        sdf.addChannel(ch);

        system.config.driver.virt = .{
            .cmd_queue = .createFromMap(driver_map_cmd),
            .resp_queue = .createFromMap(driver_map_resp),
            .cmd_cs_queue = .createFromMap(driver_map_cmd_cs),
            .resp_cs_queue = .createFromMap(driver_map_resp_cs),
            .id = ch.pd_a_id,
            .queue_capacity_bits = @intCast(std.math.log2(driverQueueCapacity(system))),
        };

        system.config.virt.driver = .{
            .cmd_queue = .createFromMap(virt_map_cmd),
            .resp_queue = .createFromMap(virt_map_resp),
            .cmd_cs_queue = .createFromMap(virt_map_cmd_cs),
            .resp_cs_queue = .createFromMap(virt_map_resp_cs),
            .id = ch.pd_b_id,
            .queue_capacity_bits = @intCast(std.math.log2(driverQueueCapacity(system))),
        };
    }

    pub fn connectClient(system: *Spi, client: Client, i: usize) void {
        const allocator = system.allocator;
        var sdf = system.sdf;
        const virt = system.virt;
        var driver = system.driver;

        system.config.virt.num_clients += 1;

        //TODO: unbodge the sizes
        const mr_cmd = Mr.create(allocator, fmt(allocator, "spi_client_cmd_{s}-{d}", .{client.pd.name, client.num_prev_occurances}), Arch.roundUpToPage(system.sdf.arch, client.queue_capacity * 32), .{});
        const mr_resp = Mr.create(allocator, fmt(allocator, "spi_client_resp_{s}-{d}", .{client.pd.name, client.num_prev_occurances}), Arch.roundUpToPage(system.sdf.arch, client.queue_capacity * 4), .{});
        const mr_data = Mr.create(allocator, fmt(allocator, "spi_client_data_{s}-{d}", .{client.pd.name, client.num_prev_occurances}), Arch.roundUpToPage(system.sdf.arch, client.data_size), .{});

        sdf.addMemoryRegion(mr_cmd);
        sdf.addMemoryRegion(mr_resp);
        sdf.addMemoryRegion(mr_data);

        const driver_map_data = Map.create(mr_data, system.driver.getMapVaddr(&mr_data), .rw, .{ .cached = false });
        driver.addMap(driver_map_data);

        const virt_map_cmd = Map.create(mr_cmd, system.virt.getMapVaddr(&mr_cmd), .rw, .{});
        virt.addMap(virt_map_cmd);
        const virt_map_resp = Map.create(mr_resp, system.virt.getMapVaddr(&mr_resp), .rw, .{});
        virt.addMap(virt_map_resp);

        const client_map_cmd = Map.create(mr_cmd, client.pd.getMapVaddr(&mr_cmd), .rw, .{});
        client.pd.addMap(client_map_cmd);
        const client_map_resp = Map.create(mr_resp, client.pd.getMapVaddr(&mr_resp), .rw, .{});
        client.pd.addMap(client_map_resp);

        const client_map_data = Map.create(mr_data, client.pd.getMapVaddr(&mr_data), .rw, .{ .cached = false });
        client.pd.addMap(client_map_data);

        // Create a channel between the virtualiser and client
        const ch = Channel.create(virt, client.pd, .{}) catch unreachable;
        sdf.addChannel(ch);

        // The below section originally passed the virt a region structure with no vaddr for the
        // control region. Instead of doing this, just pass the size of the region.
        system.config.virt.clients[i] = .{
            .conn = .{
                .cmd_queue = .createFromMap(virt_map_cmd),
                .resp_queue = .createFromMap(virt_map_resp),
                .id = ch.pd_a_id,
                .queue_capacity_bits = @intCast(std.math.log2(client.queue_capacity)),
            },
            .data_size = client.data_size,
            .cs = client.cs,
        };

        system.config.clients.items[i] = .{
            .virt = .{
                .cmd_queue = .createFromMap(client_map_cmd),
                .resp_queue = .createFromMap(client_map_resp),
                .id = ch.pd_b_id,
                .queue_capacity_bits = @intCast(std.math.log2(client.queue_capacity)),
            },
            .data_region = .createFromMap(client_map_data),
        };

        system.config.driver.data[client.cs] = .createFromMap(driver_map_data);

        system.config.driver.dev_conf[client.cs] = .{
            .cpha = client.cpha,
            .cpol = client.cpol,
            .freq_div = client.freq_div,
        };
    }

    pub fn connect(system: *Spi) !void {
        const sdf = system.sdf;

        // 1. Create the device resources for the driver
        if (system.device) |device| {
            try createDriver(sdf, system.driver, device, .spi, &system.device_res);
        }
        // 2. Connect the driver to the virtualiser
        system.connectDriver();

        // 3. Connect each client to the virtualiser (and connect the data region to the driver)
        for (system.clients.items, 0..) |client, i| {
            system.connectClient(client, i);
        }

        // To avoid cross-core IPC, we make the virtualiser passive
        system.virt.passive = true;

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Spi, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const device_res_data_name = fmt(system.allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.config.driver, prefix, "spi_driver");
        try data.serialize(allocator, system.config.virt, prefix, "spi_virt");

        for (system.clients.items, 0..) |client, i| {
            const name = fmt(allocator, "spi_client_{s}", .{client.pd.name});
            try data.serialize(allocator, system.config.clients.items[i], prefix, name);
        }

        system.serialised = true;
    }
};
