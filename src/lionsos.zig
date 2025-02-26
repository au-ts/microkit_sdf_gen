const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_vmm = @import("vmm.zig");
const sddf = @import("sddf.zig");
const data = @import("data.zig");
const log = @import("log.zig");
const dtb = @import("dtb.zig");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Channel = SystemDescription.Channel;

const ConfigResources = data.Resources;

const Blk = sddf.Blk;
const Net = sddf.Net;
const Serial = sddf.Serial;
const Timer = sddf.Timer;

const VirtualMachineSystem = mod_vmm;

fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, s, args) catch @panic("OOM");
}

fn round_up(n: usize, d: usize) usize {
    var result = d * (n / d);
    if (n % d != 0) {
        result += d;
    }
    return result;
}

// TODO: need to put this in a better place
fn round_to_page(n: usize) usize {
    const page_size = 4096;
    return round_up(n, page_size);
}

pub const FileSystem = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    fs: *Pd,
    client: *Pd,
    // The user can optionally override the data region MR
    data_mr: ?Mr,
    data_size: usize,
    completion_queue_size: usize,
    command_queue_size: usize,

    server_config: ConfigResources.Fs.Server,
    client_config: ConfigResources.Fs.Client,

    const Options = struct {
        data_mr: ?Mr = null,
        data_size: usize = 1024 * 1024 * 64,
        // TODO: do the queue sizes need to be the same?
        completion_queue_size: usize = 0x8000,
        command_queue_size: usize = 0x8000,
    };

    const Region = enum {
        data,
        command_queue,
        completion_queue,
    };

    const Error = error{
        InvalidClient,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, options: Options) Error!FileSystem {
        if (std.mem.eql(u8, fs.name, client.name)) {
            log.err("invalid file system client, same name as file system PD '{s}", .{client.name});
            return Error.InvalidClient;
        }
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .fs = fs,
            .client = client,
            .data_mr = options.data_mr,
            .data_size = options.data_size,
            .completion_queue_size = options.completion_queue_size,
            .command_queue_size = options.command_queue_size,

            .server_config = std.mem.zeroInit(ConfigResources.Fs.Server, .{}),
            .client_config = std.mem.zeroInit(ConfigResources.Fs.Client, .{}),
        };
    }

    fn createMapping(fs: *Pd, map: Map) void {
        if (fs.vm) |vm| {
            vm.addMap(map);
        } else {
            fs.addMap(map);
        }
    }

    const ConnectOptions = struct {
        cached: ?bool = null,
        command_vaddr: ?u64 = null,
        completion_vaddr: ?u64 = null,
        share_vaddr: ?u64 = null,
    };

    pub fn connect(system: *FileSystem, options: ConnectOptions) void {
        const allocator = system.allocator;
        const fs = system.fs;
        const client = system.client;

        const fs_command_queue = Mr.create(allocator, fmt(allocator, "fs_{s}_command_queue", .{fs.name}), system.command_queue_size, .{});
        const fs_completion_queue = Mr.create(allocator, fmt(allocator, "fs_{s}_completion_queue", .{fs.name}), system.completion_queue_size, .{});

        system.sdf.addMemoryRegion(fs_command_queue);
        system.sdf.addMemoryRegion(fs_completion_queue);

        const fs_share = blk: {
            if (system.data_mr) |data_mr| {
                break :blk data_mr;
            } else {
                const mr = Mr.create(allocator, fmt(allocator, "fs_{s}_share", .{fs.name}), system.data_size, .{});
                system.sdf.addMemoryRegion(mr);
                break :blk mr;
            }
        };

        const server_command_map = Map.create(fs_command_queue, options.command_vaddr orelse fs.getMapVaddr(&fs_command_queue), .rw, .{ .cached = options.cached });
        system.server_config.client.command_queue = .createFromMap(server_command_map);
        createMapping(fs, server_command_map);

        const server_completion_map = Map.create(fs_completion_queue, options.completion_vaddr orelse fs.getMapVaddr(&fs_completion_queue), .rw, .{ .cached = options.cached });
        system.server_config.client.completion_queue = .createFromMap(server_completion_map);
        createMapping(fs, server_completion_map);

        const server_share_map = Map.create(fs_share, options.share_vaddr orelse fs.getMapVaddr(&fs_share), .rw, .{ .cached = options.cached });
        system.server_config.client.share = .createFromMap(server_share_map);
        createMapping(fs, server_share_map);

        const client_command_map = Map.create(fs_command_queue, client.getMapVaddr(&fs_command_queue), .rw, .{ .cached = options.cached });
        system.client.addMap(client_command_map);
        system.client_config.server.command_queue = .createFromMap(client_command_map);

        const client_completion_map = Map.create(fs_completion_queue, client.getMapVaddr(&fs_completion_queue), .rw, .{ .cached = options.cached });

        system.client.addMap(client_completion_map);
        system.client_config.server.completion_queue = .createFromMap(client_completion_map);

        const client_share_map = Map.create(fs_share, client.getMapVaddr(&fs_share), .rw, .{ .cached = options.cached });
        system.client.addMap(client_share_map);
        system.client_config.server.share = .createFromMap(client_share_map);

        system.server_config.client.queue_len = 512;
        system.client_config.server.queue_len = 512;

        const channel = Channel.create(system.fs, system.client, .{}) catch @panic("failed to create connection channel");
        system.sdf.addChannel(channel);
        system.server_config.client.id = channel.pd_a_id;
        system.client_config.server.id = channel.pd_b_id;
    }

    pub fn serialiseConfig(system: *FileSystem, prefix: []const u8) !void {
        const allocator = system.allocator;

        const server_config = fmt(allocator, "fs_server_{s}", .{system.fs.name});
        try data.serialize(allocator, system.server_config, prefix, server_config);

        const client_config = fmt(allocator, "fs_client_{s}", .{system.client.name});
        try data.serialize(allocator, system.client_config, prefix, client_config);
    }

    pub const Nfs = struct {
        allocator: Allocator,
        fs: FileSystem,
        data: ConfigResources.Nfs,
        serial: *Serial,
        timer: *Timer,
        net: *Net,
        net_copier: *Pd,
        mac_addr: ?[]const u8,

        const Error = FileSystem.Error || Net.Error;

        pub const Options = struct {
            server: []const u8,
            export_path: []const u8,
            mac_addr: ?[]const u8 = null,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, net: *Net, net_copier: *Pd, serial: *Serial, timer: *Timer, options: Nfs.Options) Nfs.Error!Nfs {
            var nfs_data = std.mem.zeroInit(ConfigResources.Nfs, .{});
            std.mem.copyForwards(u8, &nfs_data.server, options.server);
            std.mem.copyForwards(u8, &nfs_data.export_path, options.export_path);

            const mac_addr = if (options.mac_addr) |m| allocator.dupe(u8, m) catch @panic("OOM") else null;

            return .{
                .allocator = allocator,
                .fs = try FileSystem.init(allocator, sdf, fs, client, .{}),
                .data = nfs_data,
                .serial = serial,
                .timer = timer,
                .net = net,
                .net_copier = net_copier,
                .mac_addr = mac_addr,
            };
        }

        pub fn deinit(nfs: *Nfs) void {
            if (nfs.mac_addr) |mac_addr| {
                nfs.allocator.free(mac_addr);
            }
        }

        pub fn connect(nfs: *Nfs) !void {
            const fs_pd = nfs.fs.fs;
            // NFS depends on being connected via the network, serial, and timer sub-sytems.
            try nfs.net.addClientWithCopier(fs_pd, nfs.net_copier, .{
                .mac_addr = nfs.mac_addr,
            });
            try nfs.serial.addClient(fs_pd);
            try nfs.timer.addClient(fs_pd);

            nfs.fs.connect(.{});
        }

        pub fn serialiseConfig(nfs: *Nfs, prefix: []const u8) !void {
            try data.serialize(nfs.allocator, nfs.data, prefix, "nfs_config");
            try nfs.fs.serialiseConfig(prefix);
        }
    };

    pub const Fat = struct {
        allocator: Allocator,
        fs: FileSystem,
        data: ConfigResources.Fs,
        blk: *Blk,
        partition: u32,

        pub const Options = struct {
            partition: u32,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, blk: *Blk, options: Fat.Options) Error!Fat {
            return .{
                .allocator = allocator,
                .fs = try FileSystem.init(allocator, sdf, fs, client, .{}),
                .blk = blk,
                .partition = options.partition,
                .data = std.mem.zeroInit(ConfigResources.Fs, .{}),
            };
        }

        pub fn connect(fat: *Fat) !void {
            const allocator = fat.allocator;
            const sdf = fat.fs.sdf;
            const fs_pd = fat.fs.fs;

            try fat.blk.addClient(fs_pd, .{
                .partition = fat.partition,
            });
            fat.fs.connect(.{});
            // Special things for FATFS
            const stack1 = Mr.create(allocator, fmt(allocator, "{s}_stack1", .{fs_pd.name}), 0x40_000, .{});
            const stack2 = Mr.create(allocator, fmt(allocator, "{s}_stack2", .{fs_pd.name}), 0x40_000, .{});
            const stack3 = Mr.create(allocator, fmt(allocator, "{s}_stack3", .{fs_pd.name}), 0x40_000, .{});
            const stack4 = Mr.create(allocator, fmt(allocator, "{s}_stack4", .{fs_pd.name}), 0x40_000, .{});
            sdf.addMemoryRegion(stack1);
            sdf.addMemoryRegion(stack2);
            sdf.addMemoryRegion(stack3);
            sdf.addMemoryRegion(stack4);
            fs_pd.addMap(.create(stack1, 0xA0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_one" }));
            fs_pd.addMap(.create(stack2, 0xB0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_two" }));
            fs_pd.addMap(.create(stack3, 0xC0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_three" }));
            fs_pd.addMap(.create(stack4, 0xD0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_four" }));
        }

        pub fn serialiseConfig(fat: *Fat, prefix: []const u8) !void {
            try data.serialize(fat.allocator, fat.data, prefix, "fat_config");
            try fat.fs.serialiseConfig(prefix);
        }
    };

    pub const VmFs = struct {
        fs: FileSystem,
        data: ConfigResources.Fs,
        fs_vm_sys: *VirtualMachineSystem,
        blk: *Blk,
        virtio_device: *dtb.Node,
        partition: u32,

        const Error = FileSystem.Error;

        const UIO_SHARED_CONFIG = "vmfs_config";
        const UIO_CMD = "vmfs_command";
        const UIO_COMP = "vmfs_completion";
        const UIO_DATA = "vmfs_data";
        const UIO_FAULT = "vmfs_fault";

        const NUM_UIO_REGIONS = 5;

        pub const Options = struct {
            partition: u32,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs_vm_sys: *VirtualMachineSystem, client: *Pd, blk: *Blk, virtio_device: *dtb.Node, options: VmFs.Options) VmFs.Error!VmFs {
            return .{
                .fs_vm_sys = fs_vm_sys,
                .fs = try FileSystem.init(allocator, sdf, fs_vm_sys.vmm, client, .{}),
                .data = std.mem.zeroInit(ConfigResources.Fs, .{}),
                .blk = blk,
                .virtio_device = virtio_device,
                .partition = options.partition,
            };
        }

        pub fn connect(vmfs: *VmFs) !void {
            if (!vmfs.fs_vm_sys.connected) {
                log.err("The FS driver VM system must be connected before the FS.", .{});
                return error.OutOfOrderConnection;
            }
            if (vmfs.blk.connected) {
                log.err("The Block system must be connected after the FS.", .{});
                return error.OutOfOrderConnection;
            }
            if (vmfs.blk.serialised or vmfs.fs_vm_sys.serialised) {
                log.err("Serialisation must take place after all conections", .{});
                return error.OutOfOrderSerialisation;
            }

            if (vmfs.fs_vm_sys.data.num_linux_uio_regions != NUM_UIO_REGIONS) {
                log.err("The FS driver VM does not have the required 5 UIO regions, got {d}", .{vmfs.fs_vm_sys.data.num_linux_uio_regions});
                return error.InvalidVMConf;
            }

            try vmfs.fs_vm_sys.addVirtioMmioBlk(vmfs.virtio_device, vmfs.blk, .{
                .partition = vmfs.partition,
            });

            // Figure out where all the FS regions are supposed to go from DTB
            const compatible = dtb.LinuxUio.compatible;
            const conf_uio_reg = vmfs.fs_vm_sys.findUio(UIO_SHARED_CONFIG) orelse {
                log.err("failed to find UIO FS shared config node: expected node with compatible '{s}\\0{s}'", .{ compatible, UIO_SHARED_CONFIG });
                return error.InvalidVMConf;
            };
            const cmd_uio_reg = vmfs.fs_vm_sys.findUio(UIO_CMD) orelse {
                log.err("failed to find UIO FS command node: expected node with compatible '{s}\\0{s}'", .{ compatible, UIO_CMD });
                return error.InvalidVMConf;
            };
            const comp_uio_reg = vmfs.fs_vm_sys.findUio(UIO_COMP) orelse {
                log.err("failed to find UIO FS completion node: expected node with compatible '{s}\\0{s}'", .{ compatible, UIO_COMP });
                return error.InvalidVMConf;
            };
            const data_uio_reg = vmfs.fs_vm_sys.findUio(UIO_DATA) orelse {
                log.err("failed to find UIO FS data node: expected node with compatible '{s}\\0{s}'", .{ compatible, UIO_DATA });
                return error.InvalidVMConf;
            };

            if (vmfs.fs_vm_sys.findUio(UIO_FAULT) == null) {
                log.err("failed to find UIO FS fault data node: expected node with compatible '{s}\\0{s}'", .{ compatible, UIO_FAULT });
                return error.InvalidVMConf;
            }

            const cmd_guest_paddr = cmd_uio_reg.guest_paddr;
            const comp_guest_paddr = comp_uio_reg.guest_paddr;
            const data_guest_paddr = data_uio_reg.guest_paddr;
            vmfs.fs.connect(.{ .cached = false, .command_vaddr = cmd_guest_paddr, .completion_vaddr = comp_guest_paddr, .share_vaddr = data_guest_paddr });

            // Set up the shared configs region between guest and VMM
            const allocator = vmfs.fs.allocator;
            const config_share_size = conf_uio_reg.size;
            const config_share_guest_paddr = conf_uio_reg.guest_paddr;
            const config_share_region = Mr.create(allocator, fmt(allocator, "fs_{s}_guest_conf_share", .{vmfs.fs_vm_sys.guest.name}), config_share_size, .{});
            vmfs.fs_vm_sys.sdf.addMemoryRegion(config_share_region);

            // Finally map everything in
            const guest_config_share_map = Map.create(config_share_region, config_share_guest_paddr, .rw, .{ .cached = false });
            vmfs.fs_vm_sys.guest.addMap(guest_config_share_map);

            const vmm_config_share_map_vaddr = vmfs.fs_vm_sys.vmm.getMapVaddr(&config_share_region);
            const vmm_config_share_map = Map.create(config_share_region, vmm_config_share_map_vaddr, .rw, .{ .cached = false });
            vmfs.fs_vm_sys.vmm.addMap(vmm_config_share_map);

            // Update the UIO book keeping data in the VM system. This is why config serialisation must be deferred until everything is set up.
            conf_uio_reg.vmm_vaddr = vmm_config_share_map_vaddr;
        }

        pub fn serialiseConfig(vmfs: *VmFs, prefix: []const u8) !void {
            try data.serialize(vmfs.fs.allocator, vmfs.data, prefix, "vmfs_config");
            try vmfs.fs.serialiseConfig(prefix);
        }
    };
};

pub const Firewall = struct {
    // Inherited from the network buffer size.
    const BUFFER_SIZE = 2048;

    pub const Error = error{
        InvalidMacAddr,
    };
    // @kwinter: Add in proper error checking here.
    allocator: Allocator,
    sdf: *SystemDescription,
    network1: *Net,
    network2: *Net,
    router: *Pd,
    arp_requester: *Pd,
    arp_responder: *Pd,
    // @kwinter: All that a filter may need is in the net config structure for now.
    // We can extend this in the future.
    filters: std.ArrayList(*Pd),
    arp_responder_config: ConfigResources.Firewall.ArpResponder,
    router_config: ConfigResources.Firewall.Router,
    arp_requester_config: ConfigResources.Firewall.ArpRequester,
    filter_configs: std.ArrayList(ConfigResources.Firewall.Filter),

    // Static build time configurations for the firewall
    pub const FirewallOptions = struct {
        network1_ip: u32 = 0,
        network2_ip: u32 = 0,
        mac_addr: ?[]const u8 = null,
        arp_mac_addr: ?[]const u8 = null,
    };

    pub const FilterOptions = struct {
        protocol: u16 = 0,
        router_buffers: usize = 512,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, net1: *Net, net2: *Net, router: *Pd, arp_responder: *Pd, arp_requester: *Pd) Firewall {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .network1 = net1,
            .network2 = net2,
            .router = router,
            .arp_responder = arp_responder,
            .arp_requester = arp_requester,
            .filters = std.ArrayList(*Pd).init(allocator),
            .router_config = std.mem.zeroInit(ConfigResources.Firewall.Router, .{}),
            .arp_responder_config = std.mem.zeroInit(ConfigResources.Firewall.ArpResponder, .{}),
            .arp_requester_config = std.mem.zeroInit(ConfigResources.Firewall.ArpRequester, .{}),
            .filter_configs = std.ArrayList(ConfigResources.Firewall.Filter).init(allocator),
        };
    }

    fn parseMacAddr(mac_str: []const u8) ![6]u8 {
        var mac_arr = std.mem.zeroes([6]u8);
        var it = std.mem.splitScalar(u8, mac_str, ':');
        for (0..6) |i| {
            mac_arr[i] = try std.fmt.parseInt(u8, it.next().?, 16);
        }
        return mac_arr;
    }

    // Semantically the same as the Net.createConnection
    fn createConnection(firewall: *Firewall, filter: *Pd, filter_conn: *ConfigResources.Firewall.FilterConnection, router_conn: *ConfigResources.Firewall.FilterConnection, num_buffers: usize) void {
        const queue_mr_size = round_to_page(8 + 16 * num_buffers);

        filter_conn.num_buffers = @intCast(num_buffers);
        router_conn.num_buffers = @intCast(num_buffers);

        const free_mr_name = fmt(firewall.allocator, "firewall/queue/router/{s}/free", .{ filter.name });
        const free_mr = Mr.create(firewall.allocator, free_mr_name, queue_mr_size, .{});
        firewall.sdf.addMemoryRegion(free_mr);

        const free_mr_router_map = Map.create(free_mr, firewall.router.getMapVaddr(&free_mr), .rw, .{});
        firewall.router.addMap(free_mr_router_map);
        router_conn.free_queue = .createFromMap(free_mr_router_map);

        const free_mr_filter_map = Map.create(free_mr, filter.getMapVaddr(&free_mr), .rw, .{});
        filter.addMap(free_mr_filter_map);
        filter_conn.free_queue = .createFromMap(free_mr_filter_map);

        const active_mr_name = fmt(firewall.allocator, "firewall/queue/router/{s}/active", .{ filter.name });
        const active_mr = Mr.create(firewall.allocator, active_mr_name, queue_mr_size, .{});
        firewall.sdf.addMemoryRegion(active_mr);

        const active_mr_router_map = Map.create(active_mr, firewall.router.getMapVaddr(&active_mr), .rw, .{});
        firewall.router.addMap(active_mr_router_map);
        router_conn.active_queue = .createFromMap(active_mr_router_map);

        const active_mr_filter_map = Map.create(active_mr, filter.getMapVaddr(&active_mr), .rw, .{});
        filter.addMap(active_mr_filter_map);
        filter_conn.active_queue = .createFromMap(active_mr_filter_map);

        const channel = Channel.create(firewall.router, filter, .{}) catch @panic("failed to create connection channel");
        firewall.sdf.addChannel(channel);
        router_conn.id = channel.pd_a_id;
        filter_conn.id = channel.pd_b_id;

    }

    pub fn addFilter(firewall: *Firewall, filter: *Pd, options: FilterOptions) !void {
        // @kwinter: Add error checking for supported protocols in the future.

        var filter_options: sddf.Net.ClientOptions = .{};
        filter_options.protocol = options.protocol;
        filter_options.rx = true;
        filter_options.tx = false;

        // Add each filter to the rx of network 1.
        try firewall.network1.addClient(filter, filter_options);

        const filter_idx = firewall.filters.items.len;

        // Connect the tx of each filter to the routing component.
        firewall.filters.append(filter) catch @panic("Could not add filter to firewall.");
        firewall.filter_configs.append(std.mem.zeroInit(ConfigResources.Firewall.Filter, .{})) catch @panic("Could not add filter to firewall");

        // Create the shared memory regions needed.
        const data_mr_size = round_to_page(options.router_buffers * BUFFER_SIZE);
        // @kwinter: TODO: Whats an appropriate way to name these regions. The net system prefixes with device name.
        const data_mr_name = fmt(firewall.allocator, "firewall/router/data/filter/{s}", .{ filter.name });
        const data_mr = Mr.physical(firewall.allocator, firewall.sdf, data_mr_name, data_mr_size, .{});
        firewall.sdf.addMemoryRegion(data_mr);

        // Add the map into the router
        const data_mr_router_map = Map.create(data_mr, firewall.router.getMapVaddr(&data_mr), .r, .{});
        firewall.router.addMap(data_mr_router_map);
        firewall.router_config.filters[filter_idx].data = .createFromMap(data_mr_router_map);

        // Add the map into the filter
        const data_mr_filter_map = Map.create(data_mr, filter.getMapVaddr(&data_mr), .rw, .{});
        filter.addMap(data_mr_filter_map);
        firewall.filter_configs.items[filter_idx].data = .createFromMap(data_mr_filter_map);

        firewall.createConnection(filter, &firewall.router_config.filters[filter_idx].conn, &firewall.filter_configs.items[filter_idx].conn, options.router_buffers);

        firewall.router_config.num_filters += 1;
    }


    pub fn connect(firewall: *Firewall, firewall_options: FirewallOptions) !void {
        const allocator = firewall.allocator;

        firewall.arp_responder_config.ip = firewall_options.network1_ip;
        firewall.arp_requester_config.ip = firewall_options.network2_ip;

        var responder_options: sddf.Net.ClientOptions = .{};
        // @kwinter: Letting the MAC address be automatically selected.
        responder_options.rx = true;
        responder_options.tx = true;
        responder_options.protocol = 0x92;
        if (firewall_options.arp_mac_addr) |a| {
            responder_options.mac_addr = a;
        }

        // Connect the ARP responder to tx and rx of network 1
        try firewall.network1.addClient(firewall.arp_responder, responder_options);
        // Connect the ARP requester to tx and rx of network 2

        var requester_options: sddf.Net.ClientOptions = .{};
        // @kwinter: Letting the MAC address be automatically selected.
        requester_options.rx = true;
        requester_options.tx = true;
        requester_options.protocol = 0x92;
        if (firewall_options.arp_mac_addr) |a| {
            requester_options.mac_addr = a;
        }

        try firewall.network2.addClient(firewall.arp_requester, requester_options);

        // Connect the router to the rx of network 1 and tx of network 2
        // These router options are for the transmit of NIC1
        var router_options: sddf.Net.ClientOptions = .{};
        if (firewall_options.mac_addr) |a| {
            router_options.mac_addr = a;
        }
        router_options.rx = true;
        router_options.tx = false;
        try firewall.network1.addClient(firewall.router, router_options);
        var router2_options: sddf.Net.ClientOptions = .{};
        router2_options.rx = false;
        router2_options.tx = true;
        try firewall.network2.addClient(firewall.router, router2_options);

        // Add memory regions for the arp cache and arp queue.

        // @kwinter: Placeholder MR sizes. Fine tune this so that we're not wasting space.
        // We will also need a way to differentiate which firewall this belongs to, as we will
        // have two of these in a system, one for each direction.
        const arp_queue = Mr.create(allocator, "firewall_arp_queue", 0x10_000, .{});
        const arp_cache = Mr.create(allocator, "firewall_arp_cache", 0x10_000, .{});
        firewall.sdf.addMemoryRegion(arp_queue);
        firewall.sdf.addMemoryRegion(arp_cache);

        const router_arp_queue_map = Map.create(arp_queue, firewall.router.getMapVaddr(&arp_queue), .rw, .{});
        firewall.router.addMap(router_arp_queue_map);
        firewall.router_config.arp_requester.arp_queue = .createFromMap(router_arp_queue_map);
        // @kwinter: This can probably be read only.
        const router_arp_cache_map = Map.create(arp_cache, 0x3_000_000, .rw, .{});
        firewall.router.addMap(router_arp_cache_map);
        firewall.router_config.arp_requester.arp_cache = .createFromMap(router_arp_cache_map);

        const arp_requester_queue_map = Map.create(arp_queue, firewall.arp_requester.getMapVaddr(&arp_queue), .rw, .{});
        firewall.arp_requester.addMap(arp_requester_queue_map);
        firewall.arp_requester_config.router.arp_queue = .createFromMap(arp_requester_queue_map);
        const arp_requester_cache_map = Map.create(arp_cache, 0x3_000_000, .rw, .{});
        firewall.arp_requester.addMap(arp_requester_cache_map);
        firewall.arp_requester_config.router.arp_cache = .createFromMap(arp_requester_cache_map);

        // Create a channel between the router and ARP requester.
        const channel = Channel.create(firewall.router, firewall.arp_requester, .{}) catch @panic("failed to create connection channel");
        firewall.sdf.addChannel(channel);
        firewall.router_config.arp_requester.id = channel.pd_a_id;
        firewall.arp_requester_config.router.id = channel.pd_b_id;
    }

    pub fn serialiseConfig(firewall: *Firewall, prefix: []const u8) !void {
        // if (!firewall.connected) return Error.NotConnected;

        const allocator = firewall.allocator;

        const router_name = fmt(allocator, "router.data", .{});
        try data.serialize(firewall.router_config, try std.fs.path.join(allocator, &.{ prefix, router_name }));

        const arp_responder_name = fmt(allocator, "arp_responder.data", .{});
        try data.serialize(firewall.arp_responder_config, try std.fs.path.join(allocator, &.{ prefix, arp_responder_name }));

        const arp_requester_name = fmt(allocator, "arp_requester.data", .{});
        try data.serialize(firewall.arp_requester_config, try std.fs.path.join(allocator, &.{ prefix, arp_requester_name }));

        if (data.emit_json) {
            const router_json_name = fmt(allocator, "router.json", .{});
            try data.jsonify(firewall.router_config, try std.fs.path.join(allocator, &.{ prefix, router_json_name }));

            const arp_responder_json_name = fmt(allocator, "arp_responder.json", .{});
            try data.jsonify(firewall.arp_responder_config, try std.fs.path.join(allocator, &.{ prefix, arp_responder_json_name }));

            const arp_requester_json_name = fmt(allocator, "arp_requester.json", .{});
            try data.jsonify(firewall.arp_requester_config, try std.fs.path.join(allocator, &.{ prefix, arp_requester_json_name }));
        }

        for (firewall.filters.items, 0..) |filter, i| {
            // @kwinter: TODO - find a better naming scheme for filtering data
            const data_name = fmt(allocator, "firewall_filter_{s}.data", .{ filter.name });
            try data.serialize(firewall.filter_configs.items[i], try std.fs.path.join(allocator, &.{ prefix, data_name }));
            const json_name = fmt(allocator, "firewall_filter_{s}.json", .{ filter.name });
            try data.jsonify(firewall.filter_configs.items[i], try std.fs.path.join(allocator, &.{ prefix, json_name }));
        }
    }
};
