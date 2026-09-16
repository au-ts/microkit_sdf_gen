const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_vmm = @import("vmm.zig");
const sddf = @import("sddf/sddf.zig");
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
            // Error checking below assumes a single compatible string.
            std.debug.assert(compatible.len == 1);
            const conf_uio_reg = vmfs.fs_vm_sys.findUio(UIO_SHARED_CONFIG) orelse {
                log.err("failed to find UIO FS shared config node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_SHARED_CONFIG });
                return error.InvalidVMConf;
            };
            const cmd_uio_reg = vmfs.fs_vm_sys.findUio(UIO_CMD) orelse {
                log.err("failed to find UIO FS command node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_CMD });
                return error.InvalidVMConf;
            };
            const comp_uio_reg = vmfs.fs_vm_sys.findUio(UIO_COMP) orelse {
                log.err("failed to find UIO FS completion node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_COMP });
                return error.InvalidVMConf;
            };
            const data_uio_reg = vmfs.fs_vm_sys.findUio(UIO_DATA) orelse {
                log.err("failed to find UIO FS data node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_DATA });
                return error.InvalidVMConf;
            };

            if (vmfs.fs_vm_sys.findUio(UIO_FAULT) == null) {
                log.err("failed to find UIO FS fault data node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_FAULT });
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

pub const Pager = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    pager: *Pd,
    clients: std.array_list.Managed(*Pd),
    memory_size: usize,
    bootinfo_size: usize,
    mmap_base: u64,
    brk_base: u64,
    connected: bool = false,
    serialised: bool = false,

    server_config: ConfigResources.Pager.Server,
    client_configs: std.array_list.Managed(ConfigResources.Pager.Client),

    const Error = sddf.SystemError || error{TooManyClients};

    /// The CNodes the pager receives the caps it creates at runtime into, as
    /// (name, root CSpace slot, size_bits, post_capdl_untypeds). Slot 0 is reserved for
    /// the Microkit CNode, so these start at 1.
    const CNodes = struct {
        name: []const u8,
        slot: u8,
        size_bits: u8,
        post_capdl_untypeds: bool,
    };
    const cnodes = [_]CNodes{
        // All untyped memory left after initialisation.
        .{ .name = "untypeds", .slot = 1, .size_bits = 9, .post_capdl_untypeds = true },
        // Frames the pager retypes to satisfy faults.
        .{ .name = "frames", .slot = 2, .size_bits = 20, .post_capdl_untypeds = false },
        // Intermediate paging structures (PUD/PD/PT).
        .{ .name = "paging_structures", .slot = 3, .size_bits = 20, .post_capdl_untypeds = false },
        // Copies of the global zero page cap, one per read-only mapping.
        .{ .name = "zero_page_copies", .slot = 4, .size_bits = 20, .post_capdl_untypeds = false },
        // Per-process CSpaces created by fork().
        .{ .name = "process_cspaces", .slot = 5, .size_bits = 5, .post_capdl_untypeds = false },
        // The clients' ELF frames, populated by the Microkit tool.
        .{ .name = "elf_caps", .slot = 6, .size_bits = 12, .post_capdl_untypeds = false },
        // Copies of frame caps. A frame cap carries its own mapping, so a folio mapped
        // into more than one VSpace needs a cap per mapping.
        .{ .name = "frame_copies", .slot = 7, .size_bits = 20, .post_capdl_untypeds = false },
    };

    pub const Options = struct {
        /// Scratch memory for folio metadata and the shadow page tables
        memory_size: usize = 0x2000000,
        bootinfo_size: usize = 0x2000,
        /// Where in each client's address space its mmap arena and heap begin
        mmap_base: u64 = 0x8000000000,
        brk_base: u64 = 0x7000000000,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, pager: *Pd, options: Options) Pager {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .pager = pager,
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .memory_size = options.memory_size,
            .bootinfo_size = options.bootinfo_size,
            .mmap_base = options.mmap_base,
            .brk_base = options.brk_base,
            .server_config = std.mem.zeroInit(ConfigResources.Pager.Server, .{}),
            .client_configs = std.array_list.Managed(ConfigResources.Pager.Client).init(allocator),
        };
    }

    pub fn deinit(system: *Pager) void {
        system.clients.deinit();
        system.client_configs.deinit();
    }

    pub fn addClient(system: *Pager, client: *Pd) Error!void {
        if (std.mem.eql(u8, client.name, system.pager.name)) {
            log.err("invalid pager client, same name as pager PD '{s}'", .{client.name});
            return Error.InvalidClient;
        }
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        if (system.clients.items.len == ConfigResources.Pager.MaxClients) {
            log.err("failed to add client '{s}' to pager '{s}', maximum clients reached", .{ client.name, system.pager.name });
            return Error.TooManyClients;
        }

        // The client's stack pages are left unmapped at boot so that they fault in
        // through the pager -- that is the whole point of being paged.
        client.backed = false;

        system.clients.append(client) catch @panic("Could not add client to Pager");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Pager.Client, .{})) catch @panic("Could not add client config to Pager");
    }

    pub fn connect(system: *Pager) !void {
        const allocator = system.allocator;
        const pager = system.pager;

        const memory = Mr.create(allocator, fmt(allocator, "{s}_memory", .{pager.name}), system.memory_size, .{});
        system.sdf.addMemoryRegion(memory);
        const memory_map = Map.create(memory, pager.getMapVaddr(&memory), .rw, .{});
        pager.addMap(memory_map);
        system.server_config.memory = .createFromMap(memory_map);

        // The Microkit tool fills this with a capDLBootInfo_t describing the untypeds
        // that survived system initialisation.
        const bootinfo = Mr.create(allocator, fmt(allocator, "{s}_bootinfo", .{pager.name}), system.bootinfo_size, .{
            .prefill_bootinfo = "post_capdl_untypeds",
        });
        system.sdf.addMemoryRegion(bootinfo);
        const bootinfo_map = Map.create(bootinfo, pager.getMapVaddr(&bootinfo), .rw, .{});
        pager.addMap(bootinfo_map);
        system.server_config.bootinfo = .createFromMap(bootinfo_map);

        inline for (cnodes) |spec| {
            const cnode = SystemDescription.CNode.create(allocator, spec.name, spec.post_capdl_untypeds, spec.size_bits);
            system.sdf.addCNode(cnode);
            // pd=null because these CNodes are the pager's alone, not shared.
            pager.addCapMap(SystemDescription.CapMap.create(allocator, "cnode", spec.name, null, spec.slot));
            @field(system.server_config, spec.name) = .{ .slot = spec.slot, .size_bits = spec.size_bits };
        }
        pager.elf_caps_cnode = allocator.dupe(u8, "elf_caps") catch @panic("Could not dupe CNode name");

        for (system.clients.items, 0..) |client, i| {
            // The client needs to be able to PPC into the pager for brk/mmap/munmap/fork.
            const ch = Channel.create(pager, client, .{ .pp = .b }) catch unreachable;
            system.sdf.addChannel(ch);

            // Allocate the fault id to match the client's index here, so that the pager
            // can use what fault() hands it to index its per-client state directly.
            const fault_id = try pager.addFaultClient(client, @intCast(i));

            system.server_config.clients[i] = .{
                .id = ch.pd_a_id,
                .fault_id = fault_id,
                .mmap_base = system.mmap_base,
                .brk_base = system.brk_base,
            };
            system.client_configs.items[i] = .{
                .id = ch.pd_b_id,
                .mmap_base = system.mmap_base,
                .brk_base = system.brk_base,
            };
        }
        system.server_config.num_clients = @intCast(system.clients.items.len);

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Pager, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const server_config = fmt(allocator, "pager_server_{s}", .{system.pager.name});
        try data.serialize(allocator, system.server_config, prefix, server_config);

        for (system.clients.items, 0..) |client, i| {
            const client_config = fmt(allocator, "pager_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, client_config);
        }

        system.serialised = true;
    }
};
