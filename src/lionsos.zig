const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_sddf = @import("sddf.zig");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Channel = SystemDescription.Channel;

const NetworkSystem = mod_sddf.NetworkSystem;

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

    // TODO: check fs and client is valid
    pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, options: Options) FileSystem {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .fs = fs,
            .client = client,
            .data_mr = options.data_mr,
            .data_size = options.data_size,
            .completion_queue_size = options.completion_queue_size,
            .command_queue_size = options.command_queue_size,
        };
    }

    pub fn connect(system: *const FileSystem) void {
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

        fs.addMap(.create(fs_command_queue, fs.getMapVaddr(&fs_command_queue), .rw, .{ .setvar_vaddr = "fs_command_queue" }));
        fs.addMap(.create(fs_completion_queue, fs.getMapVaddr(&fs_completion_queue), .rw, .{ .setvar_vaddr = "fs_completion_queue" }));
        fs.addMap(.create(fs_share, fs.getMapVaddr(&fs_share), .rw, .{ .setvar_vaddr = "fs_share" }));

        client.addMap(.create(fs_command_queue, client.getMapVaddr(&fs_command_queue), .rw, .{ .setvar_vaddr = "fs_command_queue" }));
        client.addMap(.create(fs_completion_queue, client.getMapVaddr(&fs_completion_queue), .rw, .{ .setvar_vaddr = "fs_completion_queue" }));
        client.addMap(.create(fs_share, client.getMapVaddr(&fs_share), .rw, .{ .setvar_vaddr = "fs_share" }));

        system.sdf.addChannel(Channel.create(fs, client, .{
            .pd_a_id = 10,
        }) catch unreachable);
    }

    pub const Nfs = struct {
        fs: FileSystem,

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, net: *NetworkSystem, net_copier: *Pd, options: Options) !Nfs {
            try net.addClientWithCopier(fs, net_copier, .{});
            return .{
                .fs = FileSystem.init(allocator, sdf, fs, client, options),
            };
        }

        pub fn connect(nfs: *Nfs) void {
            nfs.fs.connect();
        }
    };

    pub const Fat = struct {
        fs: FileSystem,

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, options: Options) Fat {
            return .{
                .fs = FileSystem.init(allocator, sdf, fs, client, options),
            };
        }

        pub fn connect(fat: *Fat) void {
            fat.fs.connect();

            const allocator = fat.fs.allocator;
            const sdf = fat.fs.sdf;
            const fs = fat.fs.fs;

            // Special things for FATFS
            const fatfs_metadata = Mr.create(allocator, fmt(allocator, "{s}_metadata", .{fs.name}), 0x200_000, .{});
            fs.addMap(Map.create(fatfs_metadata, 0x40_000_000, .rw, .{ .setvar_vaddr = "fs_metadata" }));
            sdf.addMemoryRegion(fatfs_metadata);
            const stack1 = Mr.create(allocator, fmt(allocator, "{s}_stack1", .{fs.name}), 0x40_000, .{});
            const stack2 = Mr.create(allocator, fmt(allocator, "{s}_stack2", .{fs.name}), 0x40_000, .{});
            const stack3 = Mr.create(allocator, fmt(allocator, "{s}_stack3", .{fs.name}), 0x40_000, .{});
            const stack4 = Mr.create(allocator, fmt(allocator, "{s}_stack4", .{fs.name}), 0x40_000, .{});
            sdf.addMemoryRegion(stack1);
            sdf.addMemoryRegion(stack2);
            sdf.addMemoryRegion(stack3);
            sdf.addMemoryRegion(stack4);
            fs.addMap(.create(stack1, 0xA0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_one" }));
            fs.addMap(.create(stack2, 0xB0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_two" }));
            fs.addMap(.create(stack3, 0xC0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_three" }));
            fs.addMap(.create(stack4, 0xD0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_four" }));
        }
    };
};
