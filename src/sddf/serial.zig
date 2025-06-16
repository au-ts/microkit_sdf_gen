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

pub const Serial = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    data_size: usize,
    queue_size: usize,
    driver: *Pd,
    device: ?*dtb.Node,
    device_res: ConfigResources.Device,
    virt_rx: ?*Pd,
    virt_tx: *Pd,
    clients: std.array_list.Managed(*Pd),
    connected: bool = false,
    enable_color: bool,
    baud_rate: u32,
    serialised: bool = false,
    begin_str: [:0]const u8,

    driver_config: ConfigResources.Serial.Driver,
    virt_rx_config: ConfigResources.Serial.VirtRx,
    virt_tx_config: ConfigResources.Serial.VirtTx,
    client_configs: std.array_list.Managed(ConfigResources.Serial.Client),

    pub const Error = SystemError || error{
        InvalidVirt,
        InvalidBeginString,
    };

    const MAX_BEGIN_STR_LEN = 128;
    const DEFAULT_BEGIN_STR = "Begin input\r\n";

    pub const Options = struct {
        data_size: usize = 0x10000,
        queue_size: usize = 0x1000,
        virt_rx: ?*Pd = null,
        enable_color: bool = true,
        baud_rate: u32 = 115200,
        begin_str: [:0]const u8 = DEFAULT_BEGIN_STR,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd, virt_tx: *Pd, options: Options) Error!Serial {
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

        if (options.begin_str.len > MAX_BEGIN_STR_LEN) {
            log.err("invalid begin string '{s}', length of {} is greater than max length {}", .{ options.begin_str, options.begin_str.len, MAX_BEGIN_STR_LEN });
            return error.InvalidBeginString;
        }

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .data_size = options.data_size,
            .queue_size = options.queue_size,
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt_rx = options.virt_rx,
            .virt_tx = virt_tx,
            .enable_color = options.enable_color,
            .baud_rate = options.baud_rate,
            .begin_str = allocator.dupeZ(u8, options.begin_str) catch @panic("OOM"),

            .driver_config = std.mem.zeroInit(ConfigResources.Serial.Driver, .{}),
            .virt_rx_config = std.mem.zeroInit(ConfigResources.Serial.VirtRx, .{}),
            .virt_tx_config = std.mem.zeroInit(ConfigResources.Serial.VirtTx, .{}),
            .client_configs = std.array_list.Managed(ConfigResources.Serial.Client).init(allocator),
        };
    }

    pub fn deinit(system: *Serial) void {
        system.clients.deinit();
        system.client_configs.deinit();
        system.allocator.free(system.begin_str);
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

    fn createConnection(system: *Serial, server: *Pd, client: *Pd, data_size: usize, server_conn: *ConfigResources.Serial.Connection, client_conn: *ConfigResources.Serial.Connection) void {
        const queue_mr_name = fmt(system.allocator, "{s}/serial/queue/{s}/{s}", .{ if (system.device) |dtb_node| dtb_node.name else "generic_serial", server.name, client.name });
        const queue_mr = Mr.create(system.allocator, queue_mr_name, system.queue_size, .{});
        system.sdf.addMemoryRegion(queue_mr);

        const queue_mr_server_map = Map.create(queue_mr, server.getMapVaddr(&queue_mr), .rw, .{});
        server.addMap(queue_mr_server_map);
        server_conn.queue = .createFromMap(queue_mr_server_map);

        const queue_mr_client_map = Map.create(queue_mr, client.getMapVaddr(&queue_mr), .rw, .{});
        client.addMap(queue_mr_client_map);
        client_conn.queue = .createFromMap(queue_mr_client_map);

        const data_mr_name = fmt(system.allocator, "{s}/serial/data/{s}/{s}", .{ if (system.device) |dtb_node| dtb_node.name else "generic_serial", server.name, client.name });
        const data_mr = Mr.create(system.allocator, data_mr_name, data_size, .{});
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
        if (system.device) |dtb_node| {
            try sddf.createDriver(system.sdf, system.driver, dtb_node, .serial, &system.device_res);
        }

        system.driver_config.default_baud = system.baud_rate;

        if (system.hasRx()) {
            system.createConnection(system.driver, system.virt_rx.?, system.data_size, &system.driver_config.rx, &system.virt_rx_config.driver);

            system.virt_rx_config.num_clients = @intCast(system.clients.items.len);
            for (system.clients.items, 0..) |client, i| {
                system.createConnection(system.virt_rx.?, client, system.data_size, &system.virt_rx_config.clients[i], &system.client_configs.items[i].rx);
            }

            system.driver_config.rx_enabled = 1;

            system.virt_rx_config.switch_char = 28;
            system.virt_rx_config.terminate_num_char = '\r';

            system.virt_tx_config.enable_rx = 1;
        }

        var driver_data_size: usize = system.data_size;
        if (system.enable_color) {
            driver_data_size *= 2;
        }
        system.createConnection(system.driver, system.virt_tx, driver_data_size, &system.driver_config.tx, &system.virt_tx_config.driver);

        system.virt_tx_config.num_clients = @intCast(system.clients.items.len);
        for (system.clients.items, 0..) |client, i| {
            // assuming name is null-terminated
            @memcpy(system.virt_tx_config.clients[i].name[0..client.name.len], client.name);
            std.debug.assert(client.name.len < ConfigResources.Serial.VirtTx.MAX_NAME_LEN);
            std.debug.assert(system.virt_tx_config.clients[i].name[client.name.len] == 0);

            system.createConnection(system.virt_tx, client, system.data_size, &system.virt_tx_config.clients[i].conn, &system.client_configs.items[i].tx);
        }

        system.virt_tx_config.enable_colour = @intFromBool(system.enable_color);

        @memcpy(system.virt_tx_config.begin_str[0..system.begin_str.len], system.begin_str);
        std.debug.assert(system.virt_tx_config.begin_str[system.begin_str.len] == 0);

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
