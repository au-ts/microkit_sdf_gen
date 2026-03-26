const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const mod_sdf = @import("sdf");
const mod_vmm = mod_sdf.vmm;
const sddf = mod_sdf.sddf;
const lionsos = mod_sdf.lionsos;
const dtb = mod_sdf.dtb;
const data = mod_sdf.data;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Vm = SystemDescription.VirtualMachine;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const MicrokitBoard = enum {
    star64,
    qemu_virt_aarch64,
    odroidc4,
    maaxboard,

    pub fn fromStr(str: []const u8) !MicrokitBoard {
        inline for (std.meta.fields(MicrokitBoard)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }

        return error.BoardNotFound;
    }

    pub fn defaultUartNode(b: MicrokitBoard, blob: *dtb.Node) *dtb.Node {
        return switch (b) {
            .odroidc4 => blob.child("soc").?.child("bus@ff800000").?.child("serial@3000").?,
            .qemu_virt_aarch64 => blob.child("pl011@9000000").?,
            .star64 => blob.child("soc").?.child("serial@10000000").?,
            .maaxboard => blob.child("soc@0").?.child("bus@30800000").?.child("serial@30860000").?,
        };
    }

    pub fn defaultI2cNode(b: MicrokitBoard, blob: *dtb.Node) *dtb.Node {
        return switch (b) {
            .odroidc4 => blob.child("soc").?.child("bus@ffd00000").?.child("i2c@1d000").?,
            else => @panic("unsupported platform"),
        };
    }

    pub fn defaultBlockNode(b: MicrokitBoard, blob: *dtb.Node) *dtb.Node {
        return switch (b) {
            .qemu_virt_aarch64 => blob.child("virtio_mmio@a003e00").?,
            .maaxboard => blob.child("soc@0").?.child("bus@30800000").?.child("mmc@30b40000").?,
            else => @panic("unsupported platform"),
        };
    }

    pub fn defaultEthernetNode(b: MicrokitBoard, blob: *dtb.Node) *dtb.Node {
        return switch (b) {
            .odroidc4 => blob.child("soc").?.child("ethernet@ff3f0000").?,
            .qemu_virt_aarch64 => blob.child("virtio_mmio@a003e00").?,
            .maaxboard => blob.child("soc@0").?.child("bus@30800000").?.child("ethernet@30be0000").?,
            else => @panic("unsupported platform"),
        };
    }

    pub fn defaultTimerNode(b: MicrokitBoard, blob: *dtb.Node) *dtb.Node {
        return switch (b) {
            .odroidc4 => blob.child("soc").?.child("bus@ffd00000").?.child("watchdog@f0d0").?,
            .qemu_virt_aarch64 => blob.child("timer").?,
            .star64 => blob.child("soc").?.child("timer@13050000").?,
            .maaxboard => blob.child("soc@0").?.child("bus@30000000").?.child("timer@302d0000").?,
        };
    }

    pub fn paddrTop(b: MicrokitBoard) u64 {
        // TODO: just get this from the DTS
        return switch (b) {
            .star64 => 0x100000000,
            .qemu_virt_aarch64 => 0xa0000000,
            .odroidc4 => 0x80000000,
            .maaxboard => 0xa0000000,
        };
    }

    pub fn arch(b: MicrokitBoard) SystemDescription.Arch {
        return switch (b) {
            .star64 => .riscv64,
            .qemu_virt_aarch64, .odroidc4, .maaxboard => .aarch64,
        };
    }

    pub fn printFields() void {
        comptime var i: usize = 0;
        const fields = @typeInfo(@This()).Enum.fields;
        inline while (i < fields.len) : (i += 1) {
            std.debug.print("{s}\n", .{fields[i].name});
        }
    }
};

const Example = enum {
    webserver,
    blk,
    i2c,
    serial,
    timer,
    echo_server,

    pub fn fromStr(str: []const u8) !Example {
        inline for (std.meta.fields(Example)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }

        return error.ExampleNotFound;
    }

    pub fn generate(e: Example, allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
        switch (e) {
            .webserver => try webserver(allocator, sdf, blob),
            .blk => try blk(allocator, sdf, blob),
            .i2c => try i2c(allocator, sdf, blob),
            .serial => try serial(allocator, sdf, blob),
            .timer => try timer(allocator, sdf, blob),
            .echo_server => try echo_server(allocator, sdf, blob),
        }
    }

    pub fn printFields() void {
        comptime var i: usize = 0;
        const fields = @typeInfo(@This()).Enum.fields;
        inline while (i < fields.len) : (i += 1) {
            std.debug.print("{s}\n", .{fields[i].name});
        }
    }
};

var xml_out_path: []const u8 = "example.system";
var sddf_path: []const u8 = config.sddf;
var dtbs_path: []const u8 = config.dtbs;
var data_output: []const u8 = config.data_output;
var board: MicrokitBoard = undefined;
var example: Example = undefined;

const usage_text =
    \\Usage zig_example --board [BOARD] --example [EXAMPLE SYSTEM] [options]
    \\
    \\Examples for generating Microkit systems programmatically in Zig
    \\
    \\ Options:
    \\ --board <board>
    \\      The possible values for this option are: {s}
    \\ --example <example>
    \\      The possible values for this option are: {s}
    \\ --sdf <path>     (default: ./example.system) Path to output the generated system description file
    \\ --sddf <path>    (default: ./sddf/) Path to the sDDF repository
    \\ --dtbs <path>     (default: ./dtbs/) Path to directory of Device Tree Blobs
    \\
;

const usage_text_formatted = std.fmt.comptimePrint(usage_text, .{ MicrokitBoard.fields(), Example.fields() });

fn parseArgs(args: []const []const u8, allocator: Allocator) !void {
    const stdout = std.io.getStdOut();

    const board_fields = comptime std.meta.fields(MicrokitBoard);
    var board_options = ArrayList(u8).init(allocator);
    defer board_options.deinit();
    inline for (board_fields) |field| {
        try board_options.appendSlice("\n           ");
        try board_options.appendSlice(field.name);
    }
    const example_fields = comptime std.meta.fields(Example);
    var example_options = ArrayList(u8).init(allocator);
    defer example_options.deinit();
    inline for (example_fields) |field| {
        try example_options.appendSlice("\n           ");
        try example_options.appendSlice(field.name);
    }

    const usage_text_fmt = try std.fmt.allocPrint(allocator, usage_text, .{ board_options.items, example_options.items });
    defer allocator.free(usage_text_fmt);

    var board_given = false;
    var example_given = false;

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage_text_fmt);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--sdf")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires an argument.\n{s}", .{ arg, usage_text_fmt });
                std.process.exit(1);
            }
            xml_out_path = args[arg_i];
            std.debug.print("xml_out_path is: {s}\n", .{xml_out_path});
        } else if (std.mem.eql(u8, arg, "--board")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires an argument.\n{s}", .{ arg, usage_text_fmt });
                std.process.exit(1);
            }
            board = MicrokitBoard.fromStr(args[arg_i]) catch {
                std.debug.print("Invalid board '{s}' given\n", .{args[arg_i]});
                std.process.exit(1);
            };
            board_given = true;
        } else if (std.mem.eql(u8, arg, "--example")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires an argument.\n{s}", .{ arg, usage_text_fmt });
                std.process.exit(1);
            }
            example = Example.fromStr(args[arg_i]) catch {
                std.debug.print("Invalid example '{s}' given\n", .{args[arg_i]});
                std.process.exit(1);
            };
            example_given = true;
        } else if (std.mem.eql(u8, arg, "--sddf")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a path to the sDDF repository.\n{s}", .{ arg, usage_text_fmt });
                std.process.exit(1);
            }
            sddf_path = args[arg_i];
        } else if (std.mem.eql(u8, arg, "--dtbs")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a path to the directory holding all the DTBs.\n{s}", .{ arg, usage_text_fmt });
                std.process.exit(1);
            }
            dtbs_path = args[arg_i];
        } else {
            std.debug.print("unrecognized argument: '{s}'\n{s}", .{ arg, usage_text_fmt });
            std.process.exit(1);
        }
    }

    if (arg_i == 1) {
        try stdout.writeAll(usage_text_fmt);
        std.process.exit(1);
    }

    if (!board_given) {
        std.debug.print("Missing '--board' argument\n", .{});
        std.process.exit(1);
    } else if (!example_given) {
        std.debug.print("Missing '--example' argument\n", .{});
        std.process.exit(1);
    }
}

fn i2c(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const i2c_node = board.defaultI2cNode(blob);

    const clk_mr = Mr.physical(allocator, sdf, "clk", 0x1000, true, .{ .paddr = 0xFF63C000 });
    const gpio_mr = Mr.physical(allocator, sdf, "gpio", 0x4000, true, .{ .paddr = 0xFF634000 });

    sdf.addMemoryRegion(clk_mr);
    sdf.addMemoryRegion(gpio_mr);

    var client_ds3231 = Pd.create(allocator, "client_ds3231", "client_ds3231.elf", .{});
    sdf.addProtectionDomain(&client_ds3231);

    var client_pn532 = Pd.create(allocator, "client_pn532", "client_pn532.elf", .{});
    sdf.addProtectionDomain(&client_pn532);

    var i2c_driver = Pd.create(allocator, "i2c_driver", "i2c_driver.elf", .{});
    sdf.addProtectionDomain(&i2c_driver);
    var i2c_virt = Pd.create(allocator, "i2c_virt", "i2c_virt.elf", .{});
    sdf.addProtectionDomain(&i2c_virt);

    var i2c_system = sddf.I2c.init(allocator, sdf, i2c_node, &i2c_driver, &i2c_virt, .{});
    try i2c_system.addClient(&client_ds3231);
    try i2c_system.addClient(&client_pn532);

    i2c_driver.addMap(.create(clk_mr, i2c_driver.getMapVaddr(&clk_mr), .rw, .{ .cached = false, .setvar_vaddr = "clk_regs" }));
    i2c_driver.addMap(.create(gpio_mr, i2c_driver.getMapVaddr(&gpio_mr), .rw, .{ .cached = false, .setvar_vaddr = "gpio_regs" }));

    i2c_virt.priority = 99;
    client_ds3231.priority = 1;
    client_pn532.priority = 1;

    const timer_node = board.defaultTimerNode(blob);

    var timer_driver = Pd.create(allocator, "timer_driver", "timer_driver.elf", .{});
    sdf.addProtectionDomain(&timer_driver);

    timer_driver.priority = 101;

    var timer_system = sddf.Timer.init(allocator, sdf, timer_node, &timer_driver);
    try timer_system.addClient(&client_ds3231);
    try timer_system.addClient(&client_pn532);

    _ = try i2c_system.connect();
    try timer_system.connect();

    try i2c_system.serialiseConfig(data_output);

    try sdf.print();
}

fn blk(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const blk_node = board.defaultBlockNode(blob);

    var client = Pd.create(allocator, "client", "client.elf", .{});
    sdf.addProtectionDomain(&client);

    var blk_driver = Pd.create(allocator, "blk_driver", "blk_driver.elf", .{});
    sdf.addProtectionDomain(&blk_driver);
    var blk_virt = Pd.create(allocator, "blk_virt", "blk_virt.elf", .{});
    sdf.addProtectionDomain(&blk_virt);

    var blk_system = try sddf.Blk.init(allocator, sdf, blk_node, &blk_driver, &blk_virt, .{});
    try blk_system.addClient(&client, .{
        .partition = 0,
    });

    _ = try blk_system.connect();

    try blk_system.serialiseConfig(data_output);

    try sdf.print();
}

fn timer(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const timer_node = board.defaultTimerNode(blob);

    var timer_driver = Pd.create(allocator, "timer_driver", "timer_driver.elf", .{});
    timer_driver.priority = 254;
    sdf.addProtectionDomain(&timer_driver);

    var client = Pd.create(allocator, "client", "client.elf", .{});
    sdf.addProtectionDomain(&client);

    var timer_system = sddf.Timer.init(allocator, sdf, timer_node, &timer_driver);
    try timer_system.addClient(&client);

    try timer_system.connect();

    try timer_system.serialiseConfig(data_output);

    try sdf.print();
}

/// Webserver has the following components/subsystems
/// * serial
/// * network
/// * micropython client
/// * nfs client
fn webserver(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const uart_node = board.defaultUartNode(blob);
    var uart_driver = Pd.create(allocator, "uart_driver", "uart_driver.elf", .{});
    sdf.addProtectionDomain(&uart_driver);

    // var serial_virt_rx = Pd.create(allocator, "serial_virt_rx", "serial_virt_rx.elf");
    // sdf.addProtectionDomain(&serial_virt_rx);
    var serial_virt_tx = Pd.create(allocator, "serial_virt_tx", "serial_virt_tx.elf", .{});
    sdf.addProtectionDomain(&serial_virt_tx);

    var eth_virt_rx = Pd.create(allocator, "eth_virt_rx", "network_virt_rx.elf", .{});
    sdf.addProtectionDomain(&eth_virt_rx);
    var eth_virt_tx = Pd.create(allocator, "eth_virt_tx", "network_virt_tx.elf", .{});
    sdf.addProtectionDomain(&eth_virt_tx);

    const timer_node = board.defaultTimerNode(blob);

    var timer_driver = Pd.create(allocator, "timer_driver", "timer_driver.elf", .{});
    sdf.addProtectionDomain(&timer_driver);

    var micropython = Pd.create(allocator, "micropython", "micropython.elf", .{
        .priority = 1,
    });
    sdf.addProtectionDomain(&micropython);

    var fatfs = Pd.create(allocator, "fatfs", "fatfs.elf", .{});
    sdf.addProtectionDomain(&fatfs);

    var timer_system = sddf.Timer.init(allocator, sdf, timer_node, &timer_driver);
    try timer_system.addClient(&micropython);
    // timer_system.addClient(&nfs);

    var serial_system = try sddf.Serial.init(allocator, sdf, uart_node, &uart_driver, &serial_virt_tx, .{});
    try serial_system.addClient(&micropython);
    // serial_system.addClient(&nfs);

    const blk_node = board.defaultBlockNode(blob);

    var blk_driver = Pd.create(allocator, "blk_driver", "blk_driver.elf", .{});
    sdf.addProtectionDomain(&blk_driver);
    var blk_virt = Pd.create(allocator, "blk_virt", "blk_virt.elf", .{});
    sdf.addProtectionDomain(&blk_virt);

    var blk_system = try sddf.Blk.init(allocator, sdf, blk_node, &blk_driver, &blk_virt, .{});
    try blk_system.addClient(&fatfs, .{
        .partition = 0,
    });

    const eth_node = board.defaultEthernetNode(blob);
    var eth_driver = Pd.create(allocator, "eth_driver", "eth_driver.elf", .{});
    sdf.addProtectionDomain(&eth_driver);

    var eth_copy_mp = Pd.create(allocator, "eth_copy_mp", "copy.elf", .{});
    sdf.addProtectionDomain(&eth_copy_mp);
    // var eth_copy_nfs = Pd.create(sdf, "eth_copy_nfs", "copy.elf");
    // sdf.addProtectionDomain(&eth_copy_nfs);

    var eth_system = sddf.Net.init(allocator, sdf, eth_node, &eth_driver, &eth_virt_tx, &eth_virt_rx, .{});
    // eth_system.addClientWithCopier(&nfs, &eth_copy_nfs);
    try eth_system.addClientWithCopier(&micropython, &eth_copy_mp, .{});

    eth_driver.priority = 110;
    eth_driver.budget = 100;
    eth_driver.period = 400;

    eth_virt_rx.priority = 108;
    eth_virt_rx.budget = 100;
    eth_virt_rx.period = 500;

    eth_virt_tx.priority = 109;
    eth_virt_tx.budget = 100;
    eth_virt_tx.period = 500;

    // eth_copy_nfs.priority = 99;
    // eth_copy_nfs.budget = 100;
    // eth_copy_nfs.period = 500;

    eth_copy_mp.priority = 97;
    eth_copy_mp.budget = 20000;

    eth_copy_mp.priority = 97;
    eth_copy_mp.budget = 20000;

    uart_driver.priority = 100;

    // nfs.priority = 98;
    // nfs.stack_size = 0x10000;

    micropython.priority = 1;

    timer_driver.priority = 150;

    serial_virt_tx.priority = 99;

    try eth_system.connect();
    try timer_system.connect();
    try serial_system.connect();
    _ = try blk_system.connect();

    const fatfs_metadata = Mr.create(allocator, "fatfs_metadata", 0x200_000, true, .{});
    // TODO: fix
    fatfs.addMap(.create(fatfs_metadata, 0x40_000_000, .rw, .{ .setvar_vaddr = "fs_metadata" }));
    sdf.addMemoryRegion(fatfs_metadata);

    var fs = try lionsos.FileSystem.init(allocator, sdf, &fatfs, &micropython, .{});
    fs.connect(.{});

    try sdf.print();
}

fn kitty(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const uart_node = board.defaultUartNode(blob);

    var uart_driver = Pd.create(sdf, "uart_driver", "uart_driver.elf");
    sdf.addProtectionDomain(&uart_driver);

    var serial_virt_rx = Pd.create(sdf, "serial_virt_rx", "serial_virt_rx.elf");
    sdf.addProtectionDomain(&serial_virt_rx);
    var serial_virt_tx = Pd.create(sdf, "serial_virt_tx", "serial_virt_tx.elf");
    sdf.addProtectionDomain(&serial_virt_tx);

    var serial_system = sddf.Serial.init(allocator, sdf, uart_node, &uart_driver, &serial_virt_rx, &serial_virt_tx, .{});

    const timer_node = board.defaultTimerNode(blob);

    var timer_client = Pd.create(sdf, "timer_client", "timer_client.elf");
    sdf.addProtectionDomain(&timer_client);

    var timer_driver = Pd.create(sdf, "timer_driver", "timer_driver.elf");
    sdf.addProtectionDomain(&timer_driver);

    var timer_system = sddf.Timer.init(allocator, sdf, &timer_driver, timer_node);
    timer_system.addClient(&timer_client);
    try timer_system.connect();

    try serial_system.connect();
    std.debug.print("{s}", .{ try sdf.render() });
}

fn echo_server(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    // Timer system

    const timer_node = board.defaultTimerNode(blob);
    var timer_driver = Pd.create(allocator, "timer_driver", "timer_driver.elf", .{});
    var timer_system = sddf.Timer.init(allocator, sdf, timer_node, &timer_driver);

    // Serial system

    const uart_node = board.defaultUartNode(blob);
    var uart_driver = Pd.create(allocator, "uart_driver", "uart_driver.elf", .{});
    var serial_virt_tx = Pd.create(allocator, "serial_virt_tx", "serial_virt_tx.elf", .{});
    var serial_system = try sddf.Serial.init(allocator, sdf, uart_node, &uart_driver, &serial_virt_tx, .{});

    // Ethernet system

    const eth_node = board.defaultEthernetNode(blob);
    var eth_driver = Pd.create(allocator, "eth_driver", "eth_driver.elf", .{
        .budget = 100,
        .period = 400,
    });
    var eth_virt_rx = Pd.create(allocator, "eth_virt_rx", "network_virt_rx.elf", .{});
    var eth_virt_tx = Pd.create(allocator, "eth_virt_tx", "network_virt_tx.elf", .{});
    var eth_copy_client0 = Pd.create(allocator, "eth_copy_client0", "copy.elf", .{});
    var eth_system = sddf.Net.init(allocator, sdf, eth_node, &eth_driver, &eth_virt_tx, &eth_virt_rx, .{});

    // Benchmark PDs

    var bench_idle = Pd.create(allocator, "bench_idle", "idle.elf", .{});
    sdf.addProtectionDomain(&bench_idle);

    var bench = Pd.create(allocator, "bench", "benchmark.elf", .{});
    sdf.addProtectionDomain(&bench);

    // Clients

    var client0 = Pd.create(allocator, "client0", "lwip.elf", .{});

    // Configure benchmark

    const pd_max_name_length = 64;
    const max_children = 64;
    const BenchmarkChildConfig = extern struct {
        name: [pd_max_name_length]u8,
        child_id: u8,
    };
    const BenchmarkConfig = extern struct {
        start_channel: u8,
        stop_channel: u8,
        init_channel: u8,
        num_children: u64,
        children: [max_children]BenchmarkChildConfig,
    };
    const BenchmarkIdleConfig = extern struct {
        cycle_counters: u64,
        init_channel: u8,
    };
    const BenchmarkClientConfig = extern struct {
        cycle_counters: u64,
        start_channel: u8,
        stop_channel: u8,
    };

    const cycle_counters_mr = Mr.create(allocator, "cyclecounters", 0x1000, true, .{});
    sdf.addMemoryRegion(cycle_counters_mr);

    const cycle_counters_bench_idle_vaddr = bench_idle.getMapVaddr(&cycle_counters_mr);
    const cycle_counters_bench_idle_map = Map.create(cycle_counters_mr, cycle_counters_bench_idle_vaddr, .rw, .{});
    bench_idle.addMap(cycle_counters_bench_idle_map);

    const cycle_counters_client0_vaddr = client0.getMapVaddr(&cycle_counters_mr);
    const cycle_counters_client0_map = Map.create(cycle_counters_mr, cycle_counters_client0_vaddr, .rw, .{});
    client0.addMap(cycle_counters_client0_map);

    var bench_config = std.mem.zeroes(BenchmarkConfig);
    var idle_config = std.mem.zeroes(BenchmarkIdleConfig);
    var bench_client_config = std.mem.zeroes(BenchmarkClientConfig);

    const bench_children = [_]*Pd{
        &eth_driver,
        &uart_driver,
        &serial_virt_tx,
        &eth_virt_rx,
        &eth_copy_client0,
        &eth_virt_tx,
        &client0,
        &timer_driver,
    };
    bench_config.num_children = bench_children.len;
    for (bench_children, 0..) |child, i| {
        bench_config.children[i].child_id = try bench.addChild(child, .{});
        @memcpy(bench_config.children[i].name[0..child.name.len], child.name);
    }

    idle_config.cycle_counters = cycle_counters_bench_idle_map.vaddr;
    bench_client_config.cycle_counters = cycle_counters_client0_map.vaddr;

    // Priorities

    timer_driver.priority = 101;

    bench_idle.priority = 1;
    bench.priority = 254;

    uart_driver.priority = 100;
    serial_virt_tx.priority = 99;

    eth_driver.priority = 101;
    eth_virt_tx.priority = 100;
    eth_virt_rx.priority = 99;
    eth_copy_client0.priority = 98;

    client0.priority = 97;

    // Connections

    try timer_system.addClient(&client0);

    try serial_system.addClient(&bench);
    try serial_system.addClient(&client0);

    try eth_system.addClientWithCopier(&client0, &eth_copy_client0, .{});

    const bench_start_channel = try Channel.create(&bench, &client0, .{});
    const bench_stop_channel = try Channel.create(&bench, &client0, .{});
    const bench_init_channel = try Channel.create(&bench, &bench_idle, .{});
    sdf.addChannel(bench_start_channel);
    sdf.addChannel(bench_stop_channel);
    sdf.addChannel(bench_init_channel);
    bench_config.start_channel = bench_start_channel.pd_a_id;
    bench_config.stop_channel = bench_stop_channel.pd_a_id;
    bench_config.init_channel = bench_init_channel.pd_a_id;
    bench_client_config.start_channel = bench_start_channel.pd_b_id;
    bench_client_config.stop_channel = bench_stop_channel.pd_b_id;
    idle_config.init_channel = bench_init_channel.pd_b_id;

    try data.serialize(allocator, bench_config, data_output, "benchmark_config");
    try data.serialize(allocator, bench_client_config, data_output, "benchmark_client_config");
    try data.serialize(allocator, idle_config, data_output, "benchmark_idle_config");

    try eth_system.connect();
    try timer_system.connect();
    try serial_system.connect();

    try eth_system.serialiseConfig(data_output);
    try timer_system.serialiseConfig(data_output);
    try serial_system.serialiseConfig(data_output);

    const out = try sdf.render();
    const sdf_file = try std.fs.cwd().createFile(try std.fs.path.join(allocator, &.{ data_output, "echo_server.system" }), .{});
    defer sdf_file.close();
    try sdf_file.writeAll(out);
}

fn serial(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const uart_node = board.defaultUartNode(blob);

    var uart_driver = Pd.create(allocator, "uart_driver", "uart_driver.elf", .{});
    sdf.addProtectionDomain(&uart_driver);

    var serial_virt_rx = Pd.create(allocator, "serial_virt_rx", "serial_virt_rx.elf", .{});
    sdf.addProtectionDomain(&serial_virt_rx);
    var serial_virt_tx = Pd.create(allocator, "serial_virt_tx", "serial_virt_tx.elf", .{});
    sdf.addProtectionDomain(&serial_virt_tx);

    var client0 = Pd.create(allocator, "client0", "serial_server.elf", .{});
    sdf.addProtectionDomain(&client0);
    var client1 = Pd.create(allocator, "client1", "serial_server.elf", .{});
    sdf.addProtectionDomain(&client1);

    var serial_system = try sddf.Serial.init(allocator, sdf, uart_node, &uart_driver, &serial_virt_tx, .{ .virt_rx = &serial_virt_rx });
    try serial_system.addClient(&client0);
    try serial_system.addClient(&client1);

    uart_driver.priority = 100;
    serial_virt_tx.priority = 99;
    serial_virt_rx.priority = 98;

    try serial_system.connect();
    try serial_system.serialiseConfig(data_output);
    try sdf.print();
}

pub fn main() !void {
    // An arena allocator makes much more sense for our purposes, all we're doing is doing a bunch
    // of allocations in a linear fashion and then just tearing everything down. This has better
    // performance than something like the General Purpose Allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    try parseArgs(args, allocator);

    // Check that path to sDDF exists
    std.fs.cwd().access(sddf_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Path to sDDF '{s}' does not exist\n", .{sddf_path});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Could not access sDDF directory '{s}' due to error: {}\n", .{ sddf_path, err });
                std.process.exit(1);
            },
        }
    };

    // Check that path to DTB exists
    const board_dtb_path = try std.fmt.allocPrint(allocator, "{s}/{s}.dtb", .{ dtbs_path, @tagName(board) });
    defer allocator.free(board_dtb_path);
    std.fs.cwd().access(board_dtb_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Path to board DTB '{s}' does not exist\n", .{board_dtb_path});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Could not access DTB directory '{s}' due to error: {}\n", .{ board_dtb_path, err });
                std.process.exit(1);
            },
        }
    };

    // Read the DTB contents
    const dtb_file = try std.fs.cwd().openFile(board_dtb_path, .{});
    const dtb_size = (try dtb_file.stat()).size;
    const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    // Parse the DTB
    var blob = try dtb.parse(allocator, blob_bytes);
    // TODO: the allocator should already be known by the DTB...
    defer blob.deinit(allocator);

    try sddf.probe(allocator, sddf_path);

    const compatible_drivers = try sddf.compatibleDrivers(allocator);
    defer allocator.free(compatible_drivers);

    std.log.debug("sDDF drivers found:", .{});
    for (compatible_drivers) |driver| {
        std.log.debug("   - {s}", .{driver});
    }

    var sdf = SystemDescription.create(allocator, board.arch(), board.paddrTop());
    try example.generate(allocator, &sdf, blob);
}
