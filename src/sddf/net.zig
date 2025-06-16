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

pub const Net = struct {
    const BUFFER_SIZE = 2048;

    pub const Error = SystemError || error{
        InvalidClient,
        DuplicateCopier,
        DuplicateMacAddr,
        InvalidMacAddr,
        InvalidOptions,
    };

    pub const Options = struct {
        rx_buffers: usize = 512,
        rx_dma_mr: ?*Mr = null,
    };

    pub const ClientOptions = struct {
        rx: bool = true,
        rx_buffers: usize = 512,
        tx: bool = true,
        tx_buffers: usize = 512,
        mac_addr: ?[]const u8 = null,
    };

    pub const ClientInfo = struct {
        rx: bool = true,
        rx_buffers: usize = 512,
        tx: bool = true,
        tx_buffers: usize = 512,
        mac_addr: ?[6]u8 = null,
    };

    allocator: Allocator,
    sdf: *SystemDescription,
    device: ?*dtb.Node,

    driver: *Pd,
    virt_rx: *Pd,
    virt_tx: *Pd,
    copiers: std.array_list.Managed(?*Pd),
    clients: std.array_list.Managed(*Pd),

    device_res: ConfigResources.Device,
    driver_config: ConfigResources.Net.Driver,
    virt_rx_config: ConfigResources.Net.VirtRx,
    virt_tx_config: ConfigResources.Net.VirtTx,
    copy_configs: std.array_list.Managed(ConfigResources.Net.Copy),
    client_configs: std.array_list.Managed(ConfigResources.Net.Client),

    connected: bool = false,
    serialised: bool = false,

    rx_buffers: usize,
    maybe_rx_dma_mr: ?*Mr,
    client_info: std.array_list.Managed(ClientInfo),

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: ?*dtb.Node, driver: *Pd, virt_tx: *Pd, virt_rx: *Pd, options: Options) Net {
        if (options.rx_dma_mr) |exists_rx_dma| {
            if (exists_rx_dma.*.paddr == null) {
                @panic("rx dma region must have a physical address");
            }

            if (exists_rx_dma.*.size < options.rx_buffers * BUFFER_SIZE) {
                @panic("rx dma region must have capacity for all buffers");
            }
        }

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .copiers = std.array_list.Managed(?*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),
            .virt_rx = virt_rx,
            .virt_tx = virt_tx,

            .driver_config = std.mem.zeroInit(ConfigResources.Net.Driver, .{}),
            .virt_rx_config = std.mem.zeroInit(ConfigResources.Net.VirtRx, .{}),
            .virt_tx_config = std.mem.zeroInit(ConfigResources.Net.VirtTx, .{}),
            .copy_configs = std.array_list.Managed(ConfigResources.Net.Copy).init(allocator),
            .client_configs = std.array_list.Managed(ConfigResources.Net.Client).init(allocator),

            .client_info = std.array_list.Managed(ClientInfo).init(allocator),
            .rx_buffers = options.rx_buffers,
            .maybe_rx_dma_mr = options.rx_dma_mr,
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

    pub fn addClientWithCopier(system: *Net, client: *Pd, maybe_copier: ?*Pd, options: ClientOptions) Error!void {
        const client_idx = system.clients.items.len;

        // Check that at least rx or tx is set in ClientOptions
        if (!options.rx and !options.tx) {
            return Error.InvalidOptions;
        }

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

        if (maybe_copier) |new_copier| {
            // Check that the copier does not already exist
            for (system.copiers.items) |mabye_existing_copier| {
                if (mabye_existing_copier) |existing_copier| {
                    if (std.mem.eql(u8, existing_copier.name, new_copier.name)) {
                        return Error.DuplicateCopier;
                    }
                }
            }
        }

        system.clients.append(client) catch @panic("Could not add client to Net");
        system.client_info.append(std.mem.zeroInit(ClientInfo, .{})) catch @panic("Could not add client to Net");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Net.Client, .{})) catch @panic("Could not add client to Net");
        // We still append null copier and config
        system.copiers.append(maybe_copier) catch @panic("Could not add client to Net");
        system.copy_configs.append(std.mem.zeroInit(ConfigResources.Net.Copy, .{})) catch @panic("Could not add client to Net");

        if (options.mac_addr) |mac_addr| {
            system.client_info.items[client_idx].mac_addr = parseMacAddr(mac_addr) catch {
                std.log.err("invalid MAC address given for client '{s}': '{s}'", .{ client.name, mac_addr });
                return Error.InvalidMacAddr;
            };
        }
        system.client_info.items[client_idx].rx = options.rx;
        if (maybe_copier == null) {
            // If there is no copier, the number of rx buffers must be equal to the number of dma buffers
            system.client_info.items[client_idx].rx_buffers = system.rx_buffers;
        } else {
            system.client_info.items[client_idx].rx_buffers = options.rx_buffers;
        }
        system.client_info.items[client_idx].tx = options.tx;
        system.client_info.items[client_idx].tx_buffers = options.tx_buffers;
    }

    fn createConnection(system: *Net, server: *Pd, client: *Pd, server_conn: *ConfigResources.Net.Connection, client_conn: *ConfigResources.Net.Connection, num_buffers: u64) void {
        const queue_mr_size = system.sdf.arch.roundUpToPage(8 + 16 * num_buffers);

        server_conn.num_buffers = @intCast(num_buffers);
        client_conn.num_buffers = @intCast(num_buffers);

        const free_mr_name = fmt(system.allocator, "{s}/net/queue/{s}/{s}/free", .{ if (system.device) |dtb_node| dtb_node.name else "generic_net", server.name, client.name });
        const free_mr = Mr.create(system.allocator, free_mr_name, queue_mr_size, .{});
        system.sdf.addMemoryRegion(free_mr);

        const free_mr_server_map = Map.create(free_mr, server.getMapVaddr(&free_mr), .rw, .{});
        server.addMap(free_mr_server_map);
        server_conn.free_queue = .createFromMap(free_mr_server_map);

        const free_mr_client_map = Map.create(free_mr, client.getMapVaddr(&free_mr), .rw, .{});
        client.addMap(free_mr_client_map);
        client_conn.free_queue = .createFromMap(free_mr_client_map);

        const active_mr_name = fmt(system.allocator, "{s}/net/queue/{s}/{s}/active", .{ if (system.device) |dtb_node| dtb_node.name else "generic_net", server.name, client.name });
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

        var rx_dma_mr: Mr = undefined;
        if (system.maybe_rx_dma_mr) |supplied_rx_dma_mr| {
            rx_dma_mr = supplied_rx_dma_mr.*;
        } else {
            const rx_dma_mr_name = fmt(system.allocator, "{s}/net/rx/data/device", .{if (system.device) |dtb_node| dtb_node.name else "generic_net"});
            const rx_dma_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * BUFFER_SIZE);
            rx_dma_mr = Mr.physical(system.allocator, system.sdf, rx_dma_mr_name, rx_dma_mr_size, .{});
            system.sdf.addMemoryRegion(rx_dma_mr);
        }
        const rx_dma_virt_map = Map.create(rx_dma_mr, system.virt_rx.getMapVaddr(&rx_dma_mr), .r, .{});
        system.virt_rx.addMap(rx_dma_virt_map);
        system.virt_rx_config.data_region = .createFromMap(rx_dma_virt_map);

        const virt_rx_metadata_mr_name = fmt(system.allocator, "{s}/net/rx/virt_metadata", .{if (system.device) |dtb_node| dtb_node.name else "generic_net"});
        const virt_rx_metadata_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * 4);
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
            if (client_info.tx) {
                num_buffers += client_info.tx_buffers;
            }
        }

        system.createConnection(system.driver, system.virt_tx, &system.driver_config.virt_tx, &system.virt_tx_config.driver, num_buffers);
    }

    fn clientRxConnect(system: *Net, rx_dma_mr: Mr, client_idx: usize) void {
        const client_info = system.client_info.items[client_idx];
        const client = system.clients.items[client_idx];
        const maybe_copier = system.copiers.items[client_idx];
        var client_config = &system.client_configs.items[client_idx];
        var copier_config = &system.copy_configs.items[client_idx];
        var virt_client_config = &system.virt_rx_config.clients[system.virt_rx_config.num_clients];

        if (maybe_copier) |copier| {
            system.createConnection(system.virt_rx, copier, &virt_client_config.conn, &copier_config.virt_rx, system.rx_buffers);
            system.createConnection(copier, client, &copier_config.client, &client_config.rx, client_info.rx_buffers);

            const rx_dma_copier_map = Map.create(rx_dma_mr, copier.getMapVaddr(&rx_dma_mr), .rw, .{});
            copier.addMap(rx_dma_copier_map);
            copier_config.device_data = .createFromMap(rx_dma_copier_map);

            const client_data_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * BUFFER_SIZE);
            const client_data_mr_name = fmt(system.allocator, "{s}/net/rx/data/client/{s}", .{ if (system.device) |dtb_node| dtb_node.name else "generic_net", client.name });
            const client_data_mr = Mr.create(system.allocator, client_data_mr_name, client_data_mr_size, .{});
            system.sdf.addMemoryRegion(client_data_mr);

            const client_data_client_map = Map.create(client_data_mr, client.getMapVaddr(&client_data_mr), .rw, .{});
            client.addMap(client_data_client_map);
            client_config.rx_data = .createFromMap(client_data_client_map);

            const client_data_copier_map = Map.create(client_data_mr, copier.getMapVaddr(&client_data_mr), .rw, .{});
            copier.addMap(client_data_copier_map);
            copier_config.client_data = .createFromMap(client_data_copier_map);
        } else {
            // Communicate directly with rx virt if client has no copier
            system.createConnection(system.virt_rx, client, &virt_client_config.conn, &client_config.rx, system.rx_buffers);

            // Map in dma region directly into clients with no copier
            const rx_dma_client_map = Map.create(rx_dma_mr, client.getMapVaddr(&rx_dma_mr), .rw, .{});
            client.addMap(rx_dma_client_map);
            client_config.rx_data = .createFromMap(rx_dma_client_map);
        }
    }

    fn clientTxConnect(system: *Net, client_id: usize) void {
        const client_info = &system.client_info.items[client_id];
        const client = system.clients.items[client_id];
        var client_config = &system.client_configs.items[client_id];
        const virt_client_config = &system.virt_tx_config.clients[system.virt_tx_config.num_clients];

        system.createConnection(system.virt_tx, client, &virt_client_config.conn, &client_config.tx, client_info.tx_buffers);

        const data_mr_size = system.sdf.arch.roundUpToPage(client_info.tx_buffers * BUFFER_SIZE);
        const data_mr_name = fmt(system.allocator, "{s}/net/tx/data/client/{s}", .{ if (system.device) |dtb_node| dtb_node.name else "generic_net", client.name });
        const data_mr = Mr.physical(system.allocator, system.sdf, data_mr_name, data_mr_size, .{});
        system.sdf.addMemoryRegion(data_mr);

        const data_mr_virt_map = Map.create(data_mr, system.virt_tx.getMapVaddr(&data_mr), .r, .{});
        system.virt_tx.addMap(data_mr_virt_map);
        virt_client_config.data = .createFromMap(data_mr_virt_map);

        const data_mr_client_map = Map.create(data_mr, client.getMapVaddr(&data_mr), .rw, .{});
        client.addMap(data_mr_client_map);
        client_config.tx_data = .createFromMap(data_mr_client_map);
    }

    /// Generate a LAA (locally administered adresss) for each client
    /// that does not already have one.
    pub fn generateMacAddrs(system: *Net) void {
        const rand = std.crypto.random;
        for (system.clients.items, 0..) |_, i| {
            if (system.client_info.items[i].mac_addr == null) {
                var mac_addr: [6]u8 = undefined;
                while (true) {
                    rand.bytes(&mac_addr);
                    // In order to ensure we have generated an LAA, we set the
                    // second-least-signifcant bit of the first octet.
                    mac_addr[0] |= (1 << 1);
                    // Ensure first bit is set since this is an 'individual' address,
                    // not a 'group' address.
                    mac_addr[0] &= 0b11111110;
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
        if (system.device) |dtb_node| {
            try sddf.createDriver(system.sdf, system.driver, dtb_node, .network, &system.device_res);
        }

        const rx_dma_mr = system.rxConnectDriver();
        system.txConnectDriver();

        system.generateMacAddrs();

        for (system.clients.items, 0..) |_, i| {
            // TODO: we have an assumption that all copiers are RX copiers
            if (system.client_info.items[i].rx) {
                system.clientRxConnect(rx_dma_mr, i);
                system.virt_rx_config.num_clients += 1;
                system.virt_rx_config.clients[i].mac_addr = system.client_info.items[i].mac_addr.?;
            }
            if (system.client_info.items[i].tx) {
                system.clientTxConnect(i);
                system.virt_tx_config.num_clients += 1;
            }
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

        for (system.copiers.items, 0..) |maybe_copier, i| {
            if (maybe_copier) |copier| {
                const data_name = fmt(allocator, "net_copy_{s}", .{copier.name});
                try data.serialize(allocator, system.copy_configs.items[i], prefix, data_name);
            }
        }

        for (system.clients.items, 0..) |client, i| {
            const data_name = fmt(allocator, "net_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, data_name);
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
        const pbuf_pool_mr_name = fmt(lib.allocator, "{s}/net/lib_sddf_lwip/{s}", .{ if (lib.net.device) |dtb_node| dtb_node.name else "generic_net", lib.pd.name });
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
