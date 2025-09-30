const std = @import("std");
const builtin = @import("builtin");
const sdf = @import("sdf.zig");
const Allocator = std.mem.Allocator;

comptime {
    if (@sizeOf(usize) != 8) {
        // Why do we only support 64-bit?
        // The main problem is this file, where we serialise C structs
        // into binary for consumption by runtime programs. The problem
        // is that any implicit padding which exists will be different on 64-bit
        // vs 32-bit.
        // To allow 32-bit builds, this problem should be solved.
        @compileError("only 64-bit targets are supported");
    }
}

const MAGIC_START: [4]u8 = .{ 's', 'D', 'D', 'F' };
const LIONS_MAGIC_START: [7]u8 = .{ 'L', 'i', 'o', 'n', 's', 'O', 'S' };

/// Only emit JSON versions of the serialised configuration data
/// in debug mode.
pub const emit_json = builtin.mode == .Debug;

pub const Resources = struct {
    /// Provides information to a component about a memory region that is mapped into its address space
    pub const Region = extern struct {
        pub fn create(vaddr: u64, size: u64) Region {
            return .{
                .vaddr = vaddr,
                .size = size,
            };
        }

        pub fn createFromMap(map: sdf.SystemDescription.Map) Region {
            return create(map.vaddr, map.mr.size);
        }

        vaddr: u64,
        size: u64,
    };

    /// Resources to be injected into the driver, need to match with code definition.
    pub const Device = extern struct {
        pub const MaxRegions = 64;
        pub const MaxIrqs = 64;

        const MAGIC: [5]u8 = MAGIC_START ++ .{0x1};

        pub const Region = extern struct {
            region: Resources.Region,
            io_addr: u64,

            pub fn create(vaddr: u64, size: u64, io_addr: u64) Device.Region {
                return .{
                    .region = Resources.Region.create(vaddr, size),
                    .io_addr = io_addr,
                };
            }

            pub fn createFromMap(map: sdf.SystemDescription.Map) Device.Region {
                std.debug.assert(map.mr.paddr != null);
                return create(map.vaddr, map.mr.size, map.mr.paddr.?);
            }
        };

        pub const Irq = extern struct {
            id: u8,
        };

        magic: [5]u8 = MAGIC,
        num_regions: u8,
        num_irqs: u8,
        regions: [MaxRegions]Device.Region,
        irqs: [MaxIrqs]Irq,
    };

    // For all sDDF devices classes, let's just make them have 64 clients.
    const MAX_NUM_CLIENTS: usize = 64;

    pub const Blk = struct {
        const MAGIC: [5]u8 = MAGIC_START ++ .{0x2};

        pub const Connection = extern struct {
            storage_info: Region,
            req_queue: Region,
            resp_queue: Region,
            num_buffers: u16,
            id: u8,
        };

        pub const Client = extern struct {
            magic: [5]u8 = MAGIC,
            virt: Connection,
            data: Region,
        };

        pub const Virt = extern struct {
            pub fn create(driver: Virt.Driver, clients: []const Virt.Client) Virt {
                var clients_array = std.mem.zeroes([MAX_NUM_CLIENTS]Virt.Client);
                for (clients, 0..) |client, i| {
                    clients_array[i] = client;
                }
                return .{
                    .num_clients = clients.len,
                    .driver = driver,
                    .clients = clients_array,
                };
            }

            pub const Client = extern struct {
                conn: Connection,
                data: Device.Region,
                partition: u32,
            };

            pub const Driver = extern struct {
                conn: Connection,
                data: Device.Region,
            };

            magic: [5]u8 = MAGIC,
            num_clients: u64,
            driver: Virt.Driver,
            clients: [MAX_NUM_CLIENTS]Virt.Client,
        };

        pub const Driver = extern struct {
            magic: [5]u8 = MAGIC,
            virt: Connection,
        };
    };

    pub const Serial = struct {
        const MAGIC: [5]u8 = MAGIC_START ++ .{0x3};

        pub const Connection = extern struct {
            queue: Region,
            data: Region,
            id: u8,
        };

        pub const Driver = extern struct {
            magic: [5]u8 = MAGIC,
            rx: Connection,
            tx: Connection,
            default_baud: u64,
            rx_enabled: u8,
        };

        pub const VirtRx = extern struct {
            magic: [5]u8 = MAGIC,
            driver: Connection,
            clients: [MAX_NUM_CLIENTS]Connection,
            num_clients: u8,
            switch_char: u8,
            terminate_num_char: u8,
        };

        pub const VirtTx = extern struct {
            pub const MAX_NAME_LEN = 64;
            pub const MAX_BEGIN_STR_LEN = 128;

            pub const VirtTxClient = extern struct {
                conn: Connection,
                name: [MAX_NAME_LEN]u8,
            };

            magic: [5]u8 = MAGIC,
            driver: Connection,
            clients: [MAX_NUM_CLIENTS]VirtTxClient,
            num_clients: u8,
            begin_str: [MAX_BEGIN_STR_LEN]u8,
            enable_colour: u8,
            enable_rx: u8,
        };

        pub const Client = extern struct {
            magic: [5]u8 = MAGIC,
            rx: Connection,
            tx: Connection,
        };
    };

    pub const I2c = struct {
        const MAGIC: [5]u8 = MAGIC_START ++ .{0x4};

        // SDDF Queue connection between PDs
        pub const Connection = extern struct {
            req_queue: Region,
            resp_queue: Region,
            num_buffers: u16,
            id: u8,
        };

        pub const Virt = extern struct {
            pub const Client = extern struct {
                conn: Connection,
                data_size: usize,
                driver_data_vaddr: u64, // vaddr as mapped into driver
                client_data_vaddr: u64,
            };

            magic: [5]u8 = MAGIC,
            num_clients: u64,
            driver: Connection,
            clients: [MAX_NUM_CLIENTS]Virt.Client,
        };

        pub const Driver = extern struct {
            magic: [5]u8 = MAGIC,
            virt: Connection,
        };

        pub const Client = extern struct {
            magic: [5]u8 = MAGIC,
            virt: Connection,
            data: Region,
        };
    };

    pub const Net = struct {
        const MAGIC: [5]u8 = MAGIC_START ++ .{0x5};

        pub const Connection = extern struct {
            free_queue: Region,
            active_queue: Region,
            num_buffers: u16,
            id: u8,
        };

        pub const Driver = extern struct {
            magic: [5]u8 = MAGIC,
            virt_rx: Connection,
            virt_tx: Connection,
        };

        pub const VirtRx = extern struct {
            pub const VirtRxClient = extern struct {
                conn: Connection,
                mac_addr: [6]u8,
            };

            magic: [5]u8 = MAGIC,
            driver: Connection,
            data_region: Device.Region,
            buffer_metadata: Region,
            clients: [MAX_NUM_CLIENTS]VirtRxClient,
            num_clients: u8,
        };

        pub const VirtTx = extern struct {
            pub const VirtTxClient = extern struct {
                conn: Connection,
                data: Device.Region,
            };

            magic: [5]u8 = MAGIC,
            driver: Connection,
            clients: [MAX_NUM_CLIENTS]VirtTxClient,
            num_clients: u8,
        };

        pub const Copy = extern struct {
            magic: [5]u8 = MAGIC,
            virt_rx: Connection,
            device_data: Region,
            client: Connection,
            client_data: Region,
        };

        pub const Client = extern struct {
            magic: [5]u8 = MAGIC,
            rx: Connection,
            rx_data: Region,
            tx: Connection,
            tx_data: Region,
            mac_addr: [6]u8,
        };
    };

    pub const Timer = struct {
        const MAGIC: [5]u8 = MAGIC_START ++ .{0x6};

        pub const Client = extern struct {
            magic: [5]u8 = MAGIC,
            driver_id: u8,
        };
    };

    pub const Gpu = struct {
        const MAGIC: [5]u8 = MAGIC_START ++ .{0x7};

        pub const Connection = extern struct {
            events: Region,
            req_queue: Region,
            resp_queue: Region,
            num_buffers: u16,
            id: u8,
        };

        pub const Client = extern struct {
            magic: [5]u8 = MAGIC,
            virt: Connection,
            data: Region,
        };

        pub const Virt = extern struct {
            pub fn create(driver: Virt.Driver, clients: []const Virt.Client) Virt {
                var clients_array = std.mem.zeroes([MAX_NUM_CLIENTS]Virt.Client);
                for (clients, 0..) |client, i| {
                    clients_array[i] = client;
                }
                return .{
                    .num_clients = clients.len,
                    .driver = driver,
                    .clients = clients_array,
                };
            }

            pub const Client = extern struct {
                conn: Connection,
                data: Device.Region,
            };

            pub const Driver = extern struct {
                conn: Connection,
                data: Device.Region,
            };

            magic: [5]u8 = MAGIC,
            num_clients: u64,
            driver: Virt.Driver,
            clients: [MAX_NUM_CLIENTS]Virt.Client,
        };

        pub const Driver = extern struct {
            magic: [5]u8 = MAGIC,
            virt: Connection,
            data: Region,
        };
    };

    pub const Fs = extern struct {
        const MAGIC: [8]u8 = LIONS_MAGIC_START ++ .{0x1};

        pub const Connection = extern struct {
            command_queue: Region,
            completion_queue: Region,
            share: Region,
            queue_len: u16,
            id: u8,
        };

        pub const Server = extern struct {
            magic: [8]u8 = MAGIC,
            client: Connection,
        };

        pub const Client = extern struct {
            magic: [8]u8 = MAGIC,
            server: Connection,
        };
    };

    pub const Nfs = extern struct {
        const MAGIC: [8]u8 = LIONS_MAGIC_START ++ .{0x2};
        pub const MaxServerUrlLen = 4096;
        pub const MaxExportPathLen = 4096;

        magic: [8]u8 = MAGIC,
        server: [MaxServerUrlLen]u8,
        export_path: [MaxExportPathLen]u8,
    };

    pub const Lib = struct {
        pub const SddfLwip = extern struct {
            const MAGIC: [5]u8 = MAGIC_START ++ .{0x8};

            magic: [5]u8 = MAGIC,
            pbuf_pool: Region,
            num_pbufs: u64,
        };
    };
};

pub fn serialize(allocator: Allocator, s: anytype, prefix: []const u8, path: []const u8) !void {
    const bytes = std.mem.asBytes(&s);
    const full_path = try std.fs.path.join(allocator, &.{ prefix, path });
    const full_path_data = try std.fmt.allocPrint(allocator, "{s}.data", .{full_path});
    const full_path_json = try std.fmt.allocPrint(allocator, "{s}.json", .{full_path});

    const serialize_file = try std.fs.cwd().createFile(full_path_data, .{});
    defer serialize_file.close();
    try serialize_file.writeAll(bytes);

    if (emit_json) {
        const json_file = try std.fs.cwd().createFile(full_path_json, .{});
        defer json_file.close();

        var buf: [1024]u8 = undefined;
        var writer = json_file.writer(&buf);
        var stringify: std.json.Stringify = .{ .writer = &writer.interface, .options = .{ .whitespace = .indent_4 } };
        try stringify.write(s);
        try writer.end();
    }
}
