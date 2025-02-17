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

        const server_config_data_name = fmt(allocator, "fs_server_{s}.data", .{system.fs.name});
        try data.serialize(system.server_config, try std.fs.path.join(allocator, &.{ prefix, server_config_data_name }));
        // TODO don't output json in non-debug mode
        const server_config_json_name = fmt(allocator, "fs_server_{s}.json", .{system.fs.name});
        try data.jsonify(system.server_config, try std.fs.path.join(allocator, &.{ prefix, server_config_json_name }));

        const client_config_data_name = fmt(allocator, "fs_client_{s}.data", .{system.client.name});
        try data.serialize(system.client_config, try std.fs.path.join(allocator, &.{ prefix, client_config_data_name }));
        const client_config_json_name = fmt(allocator, "fs_client_{s}.json", .{system.client.name});
        try data.jsonify(system.client_config, try std.fs.path.join(allocator, &.{ prefix, client_config_json_name }));
    }

    pub const Nfs = struct {
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
                .fs = try FileSystem.init(allocator, sdf, fs, client, .{}),
                .data = nfs_data,
                .serial = serial,
                .timer = timer,
                .net = net,
                .net_copier = net_copier,
                // TODO: free in init
                .mac_addr = mac_addr,
            };
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
            try data.serialize(nfs.data, try std.fs.path.join(nfs.fs.allocator, &.{ prefix, "nfs_config.data" }));
            nfs.fs.serialiseConfig(prefix) catch @panic("Could not serialise config");

            if (data.emit_json) {
                try data.jsonify(nfs.data, try std.fs.path.join(nfs.fs.allocator, &.{ prefix, "nfs_config.json" }));
            }
        }
    };

    pub const Fat = struct {
        fs: FileSystem,
        data: ConfigResources.Fs,
        blk: *Blk,
        partition: u32,

        pub const Options = struct {
            partition: u32,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, blk: *Blk, options: Fat.Options) Error!Fat {
            return .{
                .fs = try FileSystem.init(allocator, sdf, fs, client, .{}),
                .blk = blk,
                .partition = options.partition,
                .data = std.mem.zeroInit(ConfigResources.Fs, .{}),
            };
        }

        pub fn connect(fat: *Fat) !void {
            const allocator = fat.fs.allocator;
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
            try data.serialize(fat.data, try std.fs.path.join(fat.fs.allocator, &.{ prefix, "fat_config.data" }));
            fat.fs.serialiseConfig(prefix) catch @panic("Could not serialise config");

            if (data.emit_json) {
                try data.jsonify(fat.data, try std.fs.path.join(fat.fs.allocator, &.{ prefix, "fat_config.json" }));
            }
        }
    };

    pub const VmFs = struct {
        fs: FileSystem,
        data: ConfigResources.Fs,
        fs_vm_sys: VirtualMachineSystem,
        blk: *Blk,
        virtio_device: *dtb.Node,
        partition: u32,

        const Error = FileSystem.Error;

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
            vmfs.vmm.addVirtioMmioBlk(vmfs.virtio_device, vmfs.blk, .{
                .partition = vmfs.partition,
            });
            vmfs.fs.connect(.{ .cached = false, .command_vaddr = 0x20000000, .completion_vaddr = 0x22000000, .share_vaddr = 0x10000000 });
        }

        pub fn serialiseConfig(vmfs: *VmFs, prefix: []const u8) !void {
            try data.serialize(vmfs.data, try std.fs.path.join(vmfs.fs.allocator, &.{ prefix, "vmfs_config.data" }));
            vmfs.fs.serialiseConfig(prefix) catch @panic("Could not serialise config");

            if (data.emit_json) {
                try data.jsonify(vmfs.data, try std.fs.path.join(vmfs.fs.allocator, &.{ prefix, "vmfs_config.json" }));
            }
        }
    };
};
