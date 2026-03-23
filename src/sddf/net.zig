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

    // TODO: later share them with data.zig
    const TEMP_MAC_ADDR: u8 = 3; // TODO: this is so we can have vswitch act as a port to another vswitch
    const MAX_NUM_CLIENTS: usize = 64;
    const VSWITCH_VIRT_PORT: usize = MAX_NUM_CLIENTS - 1;
    const MAX_VSWITCH_CLIENT_PORTS: usize = MAX_NUM_CLIENTS - 1;

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
    vswitch: ?*Pd, // TODO: theoritically we could have 2, think on extending them and distinguishing between them`
    copiers: std.array_list.Managed(?*Pd),
    clients: std.array_list.Managed(*Pd),

    device_res: ConfigResources.Device,
    driver_config: ConfigResources.Net.Driver,
    virt_rx_config: ConfigResources.Net.VirtRx,
    virt_tx_config: ConfigResources.Net.VirtTx,
    vswitch_config: ConfigResources.Net.VSwitch,
    copy_configs: std.array_list.Managed(ConfigResources.Net.Copy),
    client_configs: std.array_list.Managed(ConfigResources.Net.Client),

    connected: bool = false,
    serialised: bool = false,

    rx_buffers: usize,
    maybe_rx_dma_mr: ?*Mr,
    tx_data_mrs: [MAX_NUM_CLIENTS]?Mr,
    client_info: std.array_list.Managed(ClientInfo),
    vswitch_client_ids: std.array_list.Managed(u8),
    client_id_to_virt_rx_tx: [MAX_NUM_CLIENTS]u8, // helper for properly managing indices for virts
    unique_virt_clients: u8, // number of unique virt clients from their perspective
    vswitch_virt_id: u8, // client index of vswitch presenting itself to virts
    client_id_to_port: [MAX_NUM_CLIENTS]?u8,
    port_to_client_id: [MAX_NUM_CLIENTS]?u8,
    next_vswitch_port_slot: u8,

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
            .device = device,

            .driver = driver,
            .virt_rx = virt_rx,
            .virt_tx = virt_tx,
            .vswitch = null,
            .copiers = std.array_list.Managed(?*Pd).init(allocator),
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .device_res = std.mem.zeroInit(ConfigResources.Device, .{}),

            .driver_config = std.mem.zeroInit(ConfigResources.Net.Driver, .{}),
            .virt_rx_config = std.mem.zeroInit(ConfigResources.Net.VirtRx, .{}),
            .virt_tx_config = std.mem.zeroInit(ConfigResources.Net.VirtTx, .{}),
            .vswitch_config = std.mem.zeroInit(ConfigResources.Net.VSwitch, .{}),
            .copy_configs = std.array_list.Managed(ConfigResources.Net.Copy).init(allocator),
            .client_configs = std.array_list.Managed(ConfigResources.Net.Client).init(allocator),

            .client_info = std.array_list.Managed(ClientInfo).init(allocator),
            .rx_buffers = options.rx_buffers,
            .maybe_rx_dma_mr = options.rx_dma_mr,
            .tx_data_mrs = [_]?Mr{null} ** MAX_NUM_CLIENTS,
            .vswitch_client_ids = std.array_list.Managed(u8).init(allocator),
            .client_id_to_virt_rx_tx = [_]u8{0} ** MAX_NUM_CLIENTS,
            .unique_virt_clients = 0,
            .vswitch_virt_id = 0,
            .client_id_to_port = [_]?u8{null} ** MAX_NUM_CLIENTS,
            .port_to_client_id = [_]?u8{null} ** MAX_NUM_CLIENTS,
            .next_vswitch_port_slot = 0
        };
    }

    pub fn deinit(system: *Net) void {
        system.copiers.deinit();
        system.clients.deinit();
        system.copy_configs.deinit();
        system.client_configs.deinit();
        system.client_info.deinit();
        system.vswitch_client_ids.deinit();
    }

    fn parseMacAddr(mac_str: []const u8) ![6]u8 {
        var mac_arr = std.mem.zeroes([6]u8);
        var it = std.mem.splitScalar(u8, mac_str, ':');
        for (0..6) |i| {
            mac_arr[i] = try std.fmt.parseInt(u8, it.next().?, 16);
        }
        return mac_arr;
    }

    fn deviceName(system: *Net) []const u8 {
        if (system.device) |dtb_node| {
            return dtb_node.name;
        } else {
            return "generic";
        }
    }

    pub fn addClientWithCopier(system: *Net, client: *Pd, maybe_copier: ?*Pd, maybe_vswitch: ?*Pd, options: ClientOptions) Error!void {
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

        if (maybe_vswitch) |new_vswitch| {
            // Check that the vswitch does not already exist, we don't need multiple per system
            if (system.vswitch == null) {
                system.vswitch = new_vswitch;
                system.vswitch_config = std.mem.zeroInit(ConfigResources.Net.VSwitch, .{});

                system.vswitch_virt_id = system.unique_virt_clients;
                system.unique_virt_clients += 1;
                std.log.info("Adding first client for vswitch with id {} unique_virt_clients {} vswitch virt_id {}", .{client_idx, system.unique_virt_clients, system.vswitch_virt_id});
            }

            const port_slot = system.next_vswitch_port_slot;
            if (port_slot >= MAX_VSWITCH_CLIENT_PORTS) {
                @panic("too many vswitch ports");
            }
            system.next_vswitch_port_slot += 1;
            system.client_id_to_port[client_idx] = port_slot;
            system.port_to_client_id[port_slot] = @intCast(client_idx);

            system.client_id_to_virt_rx_tx[client_idx] = system.vswitch_virt_id;
            system.vswitch_client_ids.append(@intCast(client_idx)) catch @panic("Could not add vswitch client id");

            // TODO: support more vswitches?
            std.log.info("Adding NEXT client for vswitch with id {} unique_virt_clients {} vswitch virt_id {}", .{client_idx, system.unique_virt_clients, system.vswitch_virt_id});
        } else {
            system.client_id_to_virt_rx_tx[client_idx] = system.unique_virt_clients;
            system.unique_virt_clients += 1;
            std.log.info("Adding STANDARD client with id {} unique_virt_clients {} vswitch virt_id {}", .{client_idx, system.unique_virt_clients, system.vswitch_virt_id});
        }

        std.log.info("Adding client with id {} unique_virt_clients {}", .{client_idx, system.unique_virt_clients});

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
            system.client_info.items[client_idx].rx_buffers = options.rx_buffers; // TODO: not sure about vswitch and buffers rn?
        }
        system.client_info.items[client_idx].tx = options.tx;
        system.client_info.items[client_idx].tx_buffers = options.tx_buffers;
    }

    fn createConnection(system: *Net, server: *Pd, client: *Pd, server_conn: *ConfigResources.Net.Connection, client_conn: *ConfigResources.Net.Connection, num_buffers: u64) void {
        const queue_mr_size = system.sdf.arch.roundUpToPage(8 + 16 * num_buffers);

        server_conn.num_buffers = @intCast(num_buffers);
        client_conn.num_buffers = @intCast(num_buffers);

        const free_mr_name = fmt(system.allocator, "{s}/net/queue/{s}/{s}/free", .{ system.deviceName(), server.name, client.name });
        const free_mr = Mr.create(system.allocator, free_mr_name, queue_mr_size, .{});
        system.sdf.addMemoryRegion(free_mr);

        const free_mr_server_map = Map.create(free_mr, server.getMapVaddr(&free_mr), .rw, .{});
        server.addMap(free_mr_server_map);
        server_conn.free_queue = .createFromMap(free_mr_server_map);

        const free_mr_client_map = Map.create(free_mr, client.getMapVaddr(&free_mr), .rw, .{});
        client.addMap(free_mr_client_map);
        client_conn.free_queue = .createFromMap(free_mr_client_map);

        const active_mr_name = fmt(system.allocator, "{s}/net/queue/{s}/{s}/active", .{ system.deviceName(), server.name, client.name });
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
            const rx_dma_mr_name = fmt(system.allocator, "{s}/net/rx/data/device", .{system.deviceName()});
            const rx_dma_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * BUFFER_SIZE);
            rx_dma_mr = Mr.physical(system.allocator, system.sdf, rx_dma_mr_name, rx_dma_mr_size, .{});
            system.sdf.addMemoryRegion(rx_dma_mr);
        }
        const rx_dma_virt_map = Map.create(rx_dma_mr, system.virt_rx.getMapVaddr(&rx_dma_mr), .r, .{});
        system.virt_rx.addMap(rx_dma_virt_map);
        system.virt_rx_config.data_region = .createFromMap(rx_dma_virt_map);

        const virt_rx_metadata_mr_name = fmt(system.allocator, "{s}/net/rx/virt_metadata", .{system.deviceName()});
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
        const virt_client_id = system.client_id_to_virt_rx_tx[client_idx]; // different index as we may have multiple client ids as one rx/tx client
        const client_info = system.client_info.items[client_idx];
        const client = system.clients.items[client_idx];
        const maybe_copier = system.copiers.items[client_idx];
        var client_config = &system.client_configs.items[client_idx];
        var copier_config = &system.copy_configs.items[client_idx];
        var virt_client_config = &system.virt_rx_config.clients[virt_client_id];

        std.log.info("ClientRxConnect, adding the client_id {} with virt_client_id {}", .{client_idx, virt_client_id});

        if (maybe_copier) |copier| {
            system.createConnection(system.virt_rx, copier, &virt_client_config.conn, &copier_config.virt_rx, system.rx_buffers);
            system.createConnection(copier, client, &copier_config.client, &client_config.rx, client_info.rx_buffers);

            const rx_dma_copier_map = Map.create(rx_dma_mr, copier.getMapVaddr(&rx_dma_mr), .rw, .{});
            copier.addMap(rx_dma_copier_map);
            copier_config.out_data[VSWITCH_VIRT_PORT] = .createFromMap(rx_dma_copier_map);

            const client_data_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * BUFFER_SIZE);
            const client_data_mr_name = fmt(system.allocator, "{s}/net/rx/data/client/{s}", .{ system.deviceName(), client.name });
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
        const virt_client_id = system.client_id_to_virt_rx_tx[client_id]; // different index as we may have multiple client ids as one rx/tx client
        const client_info = &system.client_info.items[client_id];
        const client = system.clients.items[client_id];
        var client_config = &system.client_configs.items[client_id];
        const virt_client_config = &system.virt_tx_config.clients[virt_client_id];

        std.log.info("ClientTxConnect, adding the client_id {} with virt_client_id {}", .{client_id, virt_client_id});

        system.createConnection(system.virt_tx, client, &virt_client_config.conn, &client_config.tx, client_info.tx_buffers);

        const data_mr_size = system.sdf.arch.roundUpToPage(client_info.tx_buffers * BUFFER_SIZE);
        const data_mr_name = fmt(system.allocator, "{s}/net/tx/data/client/{s}", .{ system.deviceName(), client.name });
        const data_mr = Mr.physical(system.allocator, system.sdf, data_mr_name, data_mr_size, .{});
        system.sdf.addMemoryRegion(data_mr);

        const data_mr_virt_map = Map.create(data_mr, system.virt_tx.getMapVaddr(&data_mr), .r, .{});
        system.virt_tx.addMap(data_mr_virt_map);
        virt_client_config.data[0] = .createFromMap(data_mr_virt_map);
        virt_client_config.num_data = 1; // always 1 for one connection

        const data_mr_client_map = Map.create(data_mr, client.getMapVaddr(&data_mr), .rw, .{});
        client.addMap(data_mr_client_map);
        client_config.tx_data = .createFromMap(data_mr_client_map);
    }

    // This also connects the copier
    pub fn clientRxVSwitchConnect(system: *Net, rx_dma_mr: Mr, client_id: usize) void {
        const port_slot = system.client_id_to_port[client_id].?;
        const client_info = system.client_info.items[client_id];
        const client = system.clients.items[client_id];
        const copier = system.copiers.items[client_id].?;
        const vswitch = system.vswitch.?;
        var client_config = &system.client_configs.items[client_id];
        var vswitch_config = &system.vswitch_config;
        var copier_config = &system.copy_configs.items[client_id];

        system.createConnection(vswitch, copier, &vswitch_config.ports[port_slot].rx, &copier_config.virt_rx, system.rx_buffers);
        system.createConnection(copier, client, &copier_config.client, &client_config.rx, client_info.rx_buffers);

        const rx_dma_copier_map = Map.create(rx_dma_mr, copier.getMapVaddr(&rx_dma_mr), .rw, .{});
        copier.addMap(rx_dma_copier_map);
        copier_config.out_data[VSWITCH_VIRT_PORT] = .createFromMap(rx_dma_copier_map);

        const client_data_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * BUFFER_SIZE);
        const client_data_mr_name = fmt(system.allocator, "{s}/net/rx/data/client/{s}", .{ system.deviceName(), client.name });
        const client_data_mr = Mr.create(system.allocator, client_data_mr_name, client_data_mr_size, .{});
        system.sdf.addMemoryRegion(client_data_mr);

        const client_data_client_map = Map.create(client_data_mr, client.getMapVaddr(&client_data_mr), .rw, .{});
        client.addMap(client_data_client_map);
        client_config.rx_data = .createFromMap(client_data_client_map);

        const client_data_copier_map = Map.create(client_data_mr, copier.getMapVaddr(&client_data_mr), .rw, .{});
        copier.addMap(client_data_copier_map);
        copier_config.client_data = .createFromMap(client_data_copier_map);
    }

    pub fn clientTxVSwitchConnect(system: *Net, client_id: usize) void {
        const port_slot = system.client_id_to_port[client_id].?;
        const client_info = &system.client_info.items[client_id];
        const client = system.clients.items[client_id];
        const vswitch = system.vswitch.?;
        var client_config = &system.client_configs.items[client_id];
        var vswitch_config = &system.vswitch_config;

        system.createConnection(vswitch, client, &vswitch_config.ports[port_slot].tx, &client_config.tx, client_info.tx_buffers);

        const data_mr_size = system.sdf.arch.roundUpToPage(client_info.tx_buffers * BUFFER_SIZE);
        const data_mr_name = fmt(system.allocator, "{s}/net/tx/data/client/{s}", .{ system.deviceName(), client.name });
        const data_mr = Mr.physical(system.allocator, system.sdf, data_mr_name, data_mr_size, .{});
        system.sdf.addMemoryRegion(data_mr);

        system.tx_data_mrs[port_slot] = data_mr;

        const data_mr_virt_map = Map.create(data_mr, system.virt_tx.getMapVaddr(&data_mr), .r, .{});
        system.virt_tx.addMap(data_mr_virt_map);

        const data_mr_vswitch_map = Map.create(data_mr, vswitch.getMapVaddr(&data_mr), .r, .{});
        vswitch.addMap(data_mr_vswitch_map);

        vswitch_config.ports[port_slot].id = @intCast(port_slot);
        vswitch_config.ports[port_slot].tx_data = .createFromMap(data_mr_vswitch_map); // TODO: not sure if I have to save it for vswitch as well?

        const data_mr_client_map = Map.create(data_mr, client.getMapVaddr(&data_mr), .rw, .{});
        client.addMap(data_mr_client_map);
        client_config.tx_data = .createFromMap(data_mr_client_map);
    }

    pub fn vswitchRxConnect(system: *Net, rx_dma_mr: Mr) void {
        const vswitch = system.vswitch.?;
        var vswitch_config = &system.vswitch_config;
        var virt_client_config = &system.virt_rx_config.clients[system.vswitch_virt_id];

        // TODO: swapping rx for tx in vswitch terminology
        system.createConnection(system.virt_rx, vswitch, &virt_client_config.conn, &vswitch_config.ports[VSWITCH_VIRT_PORT].tx, system.rx_buffers);

        std.log.info("VSwitchRxConnect, reserved virt port={}", .{VSWITCH_VIRT_PORT});

        const vswitch_metadata_mr_name = fmt(system.allocator, "{s}/net/vswitch/metadata", .{system.deviceName()});
        const vswitch_metadata_mr_size = system.sdf.arch.roundUpToPage(system.rx_buffers * 4 * MAX_NUM_CLIENTS);
        const vswitch_metadata_mr = Mr.create(system.allocator, vswitch_metadata_mr_name, vswitch_metadata_mr_size, .{});
        system.sdf.addMemoryRegion(vswitch_metadata_mr);

        const vswitch_metadata_map = Map.create(vswitch_metadata_mr, vswitch.getMapVaddr(&vswitch_metadata_mr), .rw, .{});
        vswitch.addMap(vswitch_metadata_map);
        vswitch_config.buffer_metadata = .createFromMap(vswitch_metadata_map);

        // Map in the device DMA region (as Tx as we flip rx/tx for the virt port)
        const rx_dma_vswitch_map = Map.create(rx_dma_mr, vswitch.getMapVaddr(&rx_dma_mr), .r, .{});
        vswitch.addMap(rx_dma_vswitch_map);
        vswitch_config.ports[VSWITCH_VIRT_PORT].tx_data = .createFromMap(rx_dma_vswitch_map);

        // TODO: I think this should be swapped logicallv with the similar assignment in vswitchTxConnect
        // Also fixup the existing connections for every connected Client's copier (except last one)
        for (0..system.next_vswitch_port_slot) |dst_slot| {
            const dst_client_id = system.port_to_client_id[dst_slot].?;
            var copier_config = &system.copy_configs.items[dst_client_id];
            const copier = system.copiers.items[dst_client_id].?;
            // Connect every other port under an ID
            for (0..system.next_vswitch_port_slot) |src_slot| {
                if (src_slot == dst_slot) continue;
                // Map other PDs data into Copier's PD
                const other_client_mr = system.tx_data_mrs[src_slot].?;
                const other_tx_copier_map = Map.create(other_client_mr, copier.getMapVaddr(&other_client_mr), .r, .{});
                copier.addMap(other_tx_copier_map);
                // Store the descriptor
                copier_config.out_data[src_slot] = .createFromMap(other_tx_copier_map); // TODO: do we need num_data? Probably not
            }
        }
    }

    pub fn vswitchTxConnect(system: *Net) void {
        const vswitch = system.vswitch.?;
        var vswitch_config = &system.vswitch_config;
        var virt_client_config = &system.virt_tx_config.clients[system.vswitch_virt_id];

        // TODO: swapped tx for rx in vswitch terminology
        system.createConnection(system.virt_tx, vswitch, &virt_client_config.conn, &vswitch_config.ports[VSWITCH_VIRT_PORT].rx, system.rx_buffers);
        vswitch_config.ports[VSWITCH_VIRT_PORT].id = VSWITCH_VIRT_PORT;

        std.log.info("VSwitchTxConnect, assigned the id {} at virt_id {}", .{vswitch_config.ports[VSWITCH_VIRT_PORT].rx.id, system.vswitch_virt_id});
        // for every client, we map in their TxData region
        for (0..system.next_vswitch_port_slot) |slot| {
            std.log.info("VSwitchTxConnect, mapping in port id {}", .{slot});
            virt_client_config.data[slot] = vswitch_config.ports[slot].tx_data;
        }
        virt_client_config.num_data = system.next_vswitch_port_slot;
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

    fn dumpRegion(label: []const u8, r: anytype) void {
    std.log.info("{s}: io=0x{x} vaddr=0x{x} size=0x{x}", .{
        label,
        r.io_addr,
        r.region.vaddr,
        r.region.size,
    });
}

fn dumpRegionish(label: []const u8, r: anytype) void {
    const T = @TypeOf(r);

    if (comptime @hasField(T, "io_addr") and @hasField(T, "region")) {
        std.log.info("{s}: io=0x{x} vaddr=0x{x} size=0x{x}", .{
            label,
            r.io_addr,
            r.region.vaddr,
            r.region.size,
        });
    } else if (comptime @hasField(T, "vaddr") and @hasField(T, "size")) {
        std.log.info("{s}: vaddr=0x{x} size=0x{x}", .{
            label,
            r.vaddr,
            r.size,
        });
    } else {
        @compileError("dumpRegionish: unsupported region-like type");
    }
}

fn isZeroRegionish(r: anytype) bool {
    const T = @TypeOf(r);

    if (comptime @hasField(T, "io_addr") and @hasField(T, "region")) {
        return r.io_addr == 0 and r.region.vaddr == 0 and r.region.size == 0;
    } else if (comptime @hasField(T, "vaddr") and @hasField(T, "size")) {
        return r.vaddr == 0 and r.size == 0;
    } else {
        @compileError("isZeroRegionish: unsupported region-like type");
    }
}

fn dumpConn(label: []const u8, c: anytype) void {
    std.log.info("{s}: id={} num_bufs={}", .{
        label,
        c.id,
        c.num_buffers,
    });
    dumpRegionish("  free", c.free_queue);
    dumpRegionish("  active", c.active_queue);
}

fn dumpClientMappings(system: *Net) void {
    std.log.info("========== NET CONFIG DUMP ==========", .{});
    std.log.info("unique_virt_clients={} vswitch_virt_id={} virt_rx.num_clients={} virt_tx.num_clients={} vswitch.num_ports={}", .{
        system.unique_virt_clients,
        system.vswitch_virt_id,
        system.virt_rx_config.num_clients,
        system.virt_tx_config.num_clients,
        system.vswitch_config.num_ports,
    });

    for (system.clients.items, 0..) |client, client_id| {
        const virt_id = system.client_id_to_virt_rx_tx[client_id];
        const is_vswitch_client =
            std.mem.indexOfScalar(u8, system.vswitch_client_ids.items, @intCast(client_id)) != null;

        std.log.info("--- logical client_id={} name={s} virt_id={} via_vswitch={} ---", .{
            client_id,
            client.name,
            virt_id,
            is_vswitch_client,
        });

        const ccfg = &system.client_configs.items[client_id];
        dumpConn("client.rx", ccfg.rx);
        dumpConn("client.tx", ccfg.tx);
        dumpRegionish("client.rx_data", ccfg.rx_data);
        dumpRegionish("client.tx_data", ccfg.tx_data);

        if (system.copiers.items[client_id]) |copier| {
            const copy_cfg = &system.copy_configs.items[client_id];
            std.log.info("copier={s}", .{copier.name});
            dumpConn("copy.virt_rx", copy_cfg.virt_rx);
            dumpConn("copy.client", copy_cfg.client);
            dumpRegionish("copy.client_data", copy_cfg.client_data);

            for (copy_cfg.out_data, 0..) |od, i| {
                if (isZeroRegionish(od)) continue;
                std.log.info("copy.out_data[{}]", .{i});
                dumpRegionish("  out", od);
            }
        }

        const vrx = &system.virt_rx_config.clients[virt_id];
        std.log.info("virt_rx.clients[{}]: num_macs={}", .{ virt_id, vrx.num_macs });
        dumpConn("virt_rx.conn", vrx.conn);
        for (0..vrx.num_macs) |m| {
            const base = m * 6;
            std.log.info("  mac[{}]={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                m,
                vrx.mac_addrs[base + 0],
                vrx.mac_addrs[base + 1],
                vrx.mac_addrs[base + 2],
                vrx.mac_addrs[base + 3],
                vrx.mac_addrs[base + 4],
                vrx.mac_addrs[base + 5],
            });
        }

        const vtx = &system.virt_tx_config.clients[virt_id];
        std.log.info("virt_tx.clients[{}]: num_data={}", .{ virt_id, vtx.num_data });
        dumpConn("virt_tx.conn", vtx.conn);
        for (0..vtx.num_data) |d| {
            std.log.info("virt_tx.data[{}]", .{d});
            dumpRegionish("  data", vtx.data[d]);
        }
    }

    if (system.vswitch != null) {
        std.log.info("========== VSWITCH PORTS ==========", .{});
        for (system.vswitch_config.ports, 0..) |port, port_idx| {
            if (!port.connected) continue;

            std.log.info("port[{}]: id={} connected={}", .{
                port_idx,
                port.id,
                port.connected,
            });

            dumpConn("  rx", port.rx);
            dumpConn("  tx", port.tx);
            dumpRegionish("  tx_data", port.tx_data);

            for (0..1) |_| {} // keeps formatting block tidy
            for (0..@min(1, 1)) |_| {} // no-op

            // dump MACs if present; adjust num_macs field name if needed
            if (@hasField(@TypeOf(port), "num_macs")) {
                const num_macs = @field(port, "num_macs");
                const mac_addrs = @field(port, "mac_addrs");
                for (0..num_macs) |m| {
                    const base = m * 6;
                    std.log.info("  mac[{}]={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
                        m,
                        mac_addrs[base + 0],
                        mac_addrs[base + 1],
                        mac_addrs[base + 2],
                        mac_addrs[base + 3],
                        mac_addrs[base + 4],
                        mac_addrs[base + 5],
                    });
                }
            }
        }

        std.log.info("========== VIRT RX / TX ROOT ==========", .{});
        dumpConn("virt_rx.driver", system.virt_rx_config.driver);
        dumpRegionish("virt_rx.data_region", system.virt_rx_config.data_region);
        dumpRegionish("virt_rx.buffer_metadata", system.virt_rx_config.buffer_metadata);

        dumpConn("virt_tx.driver", system.virt_tx_config.driver);
    }

    std.log.info("=====================================", .{});
}

    pub fn connect(system: *Net) !void {
        if (system.device) |dtb_node| {
            try sddf.createDriver(system.sdf, system.driver, dtb_node, .network, &system.device_res);
        }

        const rx_dma_mr = system.rxConnectDriver();
        system.txConnectDriver();

        system.generateMacAddrs();

        for (system.clients.items, 0..) |_, i| {
            // we have to split it as vswitch presents as one client to virts
            if (system.vswitch != null and std.mem.indexOfScalar(u8, system.vswitch_client_ids.items[0..], @intCast(i)) != null) {
                std.log.info("Connect: Connecting vswitch client with id {}", .{i});
                // Connect it to the vswitch
                // TODO: ask Ivan - leaving these checks as they are, IMO pointless in this case, we always need RX/TX for a client?
                if (system.client_info.items[i].rx) {
                    system.clientRxVSwitchConnect(rx_dma_mr, i);

                    // Just append the MAC to existing ones
                    const virt_client_id = system.client_id_to_virt_rx_tx[i];
                    const client = &system.virt_rx_config.clients[virt_client_id];
                    const base = client.num_macs * 6;
                    std.mem.copyForwards(u8, client.mac_addrs[base .. base + 6], &system.client_info.items[i].mac_addr.?);
                    client.num_macs += 1;
                }
                if (system.client_info.items[i].tx) {
                    system.clientTxVSwitchConnect(i);
                }
                const port_slot = system.client_id_to_port[i].?;
                system.vswitch_config.ports[port_slot].connected = true;
                system.client_configs.items[i].mac_addr = system.client_info.items[i].mac_addr.?;
            } else {
                std.log.info("Adding regular client with id {}", .{i});
                // TODO: we have an assumption that all copiers are RX copiers
                if (system.client_info.items[i].rx) {
                    system.clientRxConnect(rx_dma_mr, i);
                    system.virt_rx_config.num_clients += 1;

                    const virt_client_id = system.client_id_to_virt_rx_tx[i];
                    const client = &system.virt_rx_config.clients[virt_client_id];
                    std.mem.copyForwards(u8, client.mac_addrs[0 .. 6], &system.client_info.items[i].mac_addr.?);
                    client.num_macs += 1;
                }
                if (system.client_info.items[i].tx) {
                    system.clientTxConnect(i);
                    system.virt_tx_config.num_clients += 1;
                }
                system.client_configs.items[i].mac_addr = system.client_info.items[i].mac_addr.?;
            }
        }

        if (system.vswitch != null) {
            system.vswitchRxConnect(rx_dma_mr);
            system.vswitchTxConnect();
            // Present itself just as one client to virts
            system.virt_rx_config.num_clients += 1;
            system.virt_tx_config.num_clients += 1;

            // Mark it as index MAX_NUM_CLIENTS - 1
            system.vswitch_config.ports[VSWITCH_VIRT_PORT].connected = true;
            system.vswitch_config.num_ports = system.next_vswitch_port_slot + 1;

            // Fill in MAC addresses
            for (system.vswitch_client_ids.items[0..]) |id| {
                const port_slot = system.client_id_to_port[id].?;
                std.mem.copyForwards(u8, system.vswitch_config.ports[port_slot].mac_addrs[0 .. 6],  &system.client_info.items[id].mac_addr.?); // TODO: later extend to multiple MACs behind a port
            }
        }

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Net, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        dumpClientMappings(system);
        const allocator = system.allocator;

        const device_res_data_name = fmt(allocator, "{s}_device_resources", .{system.driver.name});
        try data.serialize(allocator, system.device_res, prefix, device_res_data_name);
        try data.serialize(allocator, system.driver_config, prefix, "net_driver");
        try data.serialize(allocator, system.virt_rx_config, prefix, "net_virt_rx");
        try data.serialize(allocator, system.virt_tx_config, prefix, "net_virt_tx");
        if (system.vswitch != null)
            try data.serialize(allocator, system.vswitch_config, prefix, "net_vswitch"); // TODO: extend to multiple later

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
        const pbuf_pool_mr_name = fmt(lib.allocator, "{s}/net/lib_sddf_lwip/{s}", .{ lib.net.deviceName(), lib.pd.name });
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
