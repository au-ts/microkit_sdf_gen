const std = @import("std");
const builtin = @import("builtin");
const mod_sdf = @import("sdf.zig");
const mod_vmm = @import("vmm.zig");
const sddf = @import("sddf.zig");
const dtb = @import("dtb");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Vm = SystemDescription.VirtualMachine;
const ProgramImage = Pd.ProgramImage;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const VirtualMachineSystem = mod_vmm.VirtualMachineSystem;

const MicrokitBoard = enum {
    qemu_arm_virt,
    odroidc4,

    pub fn fromStr(str: []const u8) !MicrokitBoard {
        inline for (std.meta.fields(MicrokitBoard)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }

        return error.BoardNotFound;
    }

    pub fn arch(b: MicrokitBoard) SystemDescription.Arch {
        return switch (b) {
            .qemu_arm_virt, .odroidc4 => .aarch64,
        };
    }

    pub fn printFields() void {
        comptime var i: usize = 0;
        const fields = @typeInfo(@This()).Enum.fields;
        inline while (i < fields.len) : (i += 1) {
            std.debug.print("{s}\n", .{fields[i].name});
        }
    }

    /// Get the Device Tree node for the UART we want to use for
    /// each board
    pub fn uartNode(b: MicrokitBoard) []const u8 {
        return switch (b) {
            .qemu_arm_virt => "pl011@9000000",
            .odroidc4 => "serial@3000",
        };
    }
};

const Example = enum {
    virtio,
    virtio_blk,
    abstractions,
    gdb,
    kitty,

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
            .virtio => try virtio(sdf),
            .abstractions => try abstractions(allocator, sdf, blob),
            .virtio_blk => try virtio_blk(allocator, sdf, blob),
            .gdb => try gdb(allocator, sdf, blob),
            .kitty => try kitty(allocator, sdf, blob),
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

// In the future, this functionality regarding the UART
// can just be replaced by looking at the device tree for
// the particular board.
const Uart = struct {
    fn paddr(b: MicrokitBoard) usize {
        return switch (b) {
            .qemu_arm_virt => 0x9000000,
            .odroidc4 => 0xff803000,
        };
    }

    fn size(b: MicrokitBoard) usize {
        return switch (b) {
            .qemu_arm_virt, .odroidc4 => 0x1000,
        };
    }

    fn irq(b: MicrokitBoard) usize {
        return switch (b) {
            .qemu_arm_virt => 33,
            .odroidc4 => 225,
        };
    }

    fn trigger(b: MicrokitBoard) Irq.Trigger {
        return switch (b) {
            .qemu_arm_virt => .level,
            .odroidc4 => .edge,
        };
    }
};

fn guestRamVaddr(b: MicrokitBoard) usize {
    return switch (b) {
        .qemu_arm_virt => 0x40000000,
        .odroidc4 => 0x20000000,
    };
}

var xml_out_path: []const u8 = "example.system";
var sddf_path: []const u8 = "sddf";
var dtbs_path: []const u8 = "dtbs";
var board: MicrokitBoard = undefined;
var example: Example = undefined;

const usage_text =
    \\Usage sdfgen --board [BOARD] --example [EXAMPLE SYSTEM] [options]
    \\
    \\Generates a Microkit system description file programatically
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

fn parseDriver(allocator: Allocator) !std.json.Parsed(sddf.Config.Driver) {
    const path = "examples/driver.json";
    const driver_description = try std.fs.cwd().openFile(path, .{});
    defer driver_description.close();

    const bytes = try driver_description.reader().readAllAlloc(allocator, 2048);

    const driver = try std.json.parseFromSlice(sddf.Config.Driver, allocator, bytes, .{});

    // std.debug.print("{}\n", .{ std.json.fmt(driver.value, .{ .whitespace = .indent_2 }) });

    return driver;
}

fn virtio(sdf: *SystemDescription) !void {
    const SDDF_BUF_SIZE: usize = 1024 * 1024 * 2;
    const GUEST_RAM_SIZE: usize = 1024 * 1024 * 128;

    // 1. Create UART driver and map in UART device
    const uart_driver_image = ProgramImage.create("uart_driver.elf");
    var uart_driver = Pd.create(sdf, "uart_driver", uart_driver_image);
    uart_driver.priority = 100;
    sdf.addProtectionDomain(uart_driver.*);

    const uart_mr = Mr.create(sdf, "uart", Uart.size(board), Uart.paddr(board), .small);
    sdf.addMemoryRegion(uart_mr);
    uart_driver.addMap(Map.create(uart_mr, 0x5_000_000, .{ .read = true, .write = true }, false, "uart_base"));

    const uart_irq = Irq.create(Uart.irq(board), Uart.trigger(board), null);
    try uart_driver.addInterrupt(uart_irq);

    // 2. Create MUX RX
    const serial_mux_rx_image = ProgramImage.create("serial_mux_rx.elf");
    var serial_mux_rx = Pd.create(sdf, "serial_mux_rx", serial_mux_rx_image);
    serial_mux_rx.priority = 98;
    sdf.addProtectionDomain(serial_mux_rx.*);

    // 3. Create MUX TX
    const serial_mux_tx_image = ProgramImage.create("serial_mux_tx.elf");
    var serial_mux_tx = Pd.create(sdf, "serial_mux_tx", serial_mux_tx_image);
    serial_mux_tx.priority = 99;
    sdf.addProtectionDomain(serial_mux_tx.*);

    // 4. Create native serial device
    const serial_tester_image = ProgramImage.create("serial_tester.elf");
    var serial_tester = Pd.create(sdf, "serial_tester", serial_tester_image);
    serial_tester.priority = 97;
    sdf.addProtectionDomain(serial_tester.*);

    // 5. Connect UART driver and MUX RX
    const rx_free = Mr.create(sdf, "rx_free_driver", SDDF_BUF_SIZE, null, .large);
    const rx_used = Mr.create(sdf, "rx_used_driver", SDDF_BUF_SIZE, null, .large);
    const rx_data = Mr.create(sdf, "rx_data_driver", SDDF_BUF_SIZE, null, .large);
    sdf.addMemoryRegion(rx_free);
    sdf.addMemoryRegion(rx_used);
    sdf.addMemoryRegion(rx_data);

    const rx_free_map = Map.create(rx_free, 0x20_000_000, .{ .read = true, .write = true }, true, "rx_free");
    const rx_used_map = Map.create(rx_used, 0x20_200_000, .{ .read = true, .write = true }, true, "rx_used");
    const rx_data_map = Map.create(rx_data, 0x20_400_000, .{ .read = true, .write = true }, true, null);

    serial_mux_rx.addMap(rx_free_map);
    serial_mux_rx.addMap(rx_used_map);
    serial_mux_rx.addMap(rx_data_map);
    uart_driver.addMap(rx_free_map);
    uart_driver.addMap(rx_used_map);
    uart_driver.addMap(rx_data_map);

    const uart_mux_rx_channel = Channel.create(uart_driver, serial_mux_rx);
    sdf.addChannel(uart_mux_rx_channel);

    // 6. Connect UART driver and MUX TX
    const tx_free = Mr.create(sdf, "tx_free_driver", SDDF_BUF_SIZE, null, .large);
    const tx_used = Mr.create(sdf, "tx_used_driver", SDDF_BUF_SIZE, null, .large);
    const tx_data = Mr.create(sdf, "tx_data_driver", SDDF_BUF_SIZE, null, .large);
    sdf.addMemoryRegion(tx_free);
    sdf.addMemoryRegion(tx_used);
    sdf.addMemoryRegion(tx_data);

    const tx_free_map = Map.create(tx_free, 0x40_000_000, .{ .read = true, .write = true }, true, "tx_free");
    const tx_used_map = Map.create(tx_used, 0x40_200_000, .{ .read = true, .write = true }, true, "tx_used");
    const tx_data_map = Map.create(tx_data, 0x40_400_000, .{ .read = true, .write = true }, true, null);

    serial_mux_tx.addMap(tx_free_map);
    serial_mux_tx.addMap(tx_used_map);
    serial_mux_tx.addMap(tx_data_map);
    uart_driver.addMap(tx_free_map);
    uart_driver.addMap(tx_used_map);
    uart_driver.addMap(tx_data_map);

    const uart_mux_tx_ch = Channel.create(uart_driver, serial_mux_tx);
    sdf.addChannel(uart_mux_tx_ch);

    // 7. Connect MUX RX and serial tester
    const rx_free_serial_tester = Mr.create(sdf, "rx_free_serial_tester", SDDF_BUF_SIZE, null, .large);
    const rx_used_serial_tester = Mr.create(sdf, "rx_used_serial_tester", SDDF_BUF_SIZE, null, .large);
    const rx_data_serial_tester = Mr.create(sdf, "rx_data_serial_tester", SDDF_BUF_SIZE, null, .large);
    sdf.addMemoryRegion(rx_free_serial_tester);
    sdf.addMemoryRegion(rx_used_serial_tester);
    sdf.addMemoryRegion(rx_data_serial_tester);

    const rx_free_serial_tester_map = Map.create(rx_free_serial_tester, 0x60_000_000, .{ .read = true, .write = true }, true, null);
    const rx_used_serial_tester_map = Map.create(rx_used_serial_tester, 0x60_200_000, .{ .read = true, .write = true }, true, null);
    const rx_data_serial_tester_map = Map.create(rx_data_serial_tester, 0x60_400_000, .{ .read = true, .write = true }, true, null);
    serial_mux_rx.addMap(rx_free_serial_tester_map);
    serial_mux_rx.addMap(rx_used_serial_tester_map);
    serial_mux_rx.addMap(rx_data_serial_tester_map);
    serial_tester.addMap(rx_free_serial_tester_map);
    serial_tester.addMap(rx_used_serial_tester_map);
    serial_tester.addMap(rx_data_serial_tester_map);

    const serial_mux_rx_tester_ch = Channel.create(serial_mux_rx, serial_tester);
    sdf.addChannel(serial_mux_rx_tester_ch);

    // 8. Connect MUX TX and serial tester
    const tx_free_serial_tester = Mr.create(sdf, "tx_free_serial_tester", SDDF_BUF_SIZE, null, .large);
    const tx_used_serial_tester = Mr.create(sdf, "tx_used_serial_tester", SDDF_BUF_SIZE, null, .large);
    const tx_data_serial_tester = Mr.create(sdf, "tx_data_serial_tester", SDDF_BUF_SIZE, null, .large);
    sdf.addMemoryRegion(tx_free_serial_tester);
    sdf.addMemoryRegion(tx_used_serial_tester);
    sdf.addMemoryRegion(tx_data_serial_tester);

    const tx_free_serial_tester_map = Map.create(tx_free_serial_tester, 0x80_000_000, .{ .read = true, .write = true }, true, null);
    const tx_used_serial_tester_map = Map.create(tx_used_serial_tester, 0x80_200_000, .{ .read = true, .write = true }, true, null);
    const tx_data_serial_tester_map = Map.create(tx_data_serial_tester, 0x80_400_000, .{ .read = true, .write = true }, true, null);
    serial_mux_tx.addMap(tx_free_serial_tester_map);
    serial_mux_tx.addMap(tx_used_serial_tester_map);
    serial_mux_tx.addMap(tx_data_serial_tester_map);
    serial_tester.addMap(tx_free_serial_tester_map);
    serial_tester.addMap(tx_used_serial_tester_map);
    serial_tester.addMap(tx_data_serial_tester_map);

    // 9. Create the virtual machine and virtual-machine-monitor
    const vmm_image = ProgramImage.create("vmm.elf");
    var vmm = Pd.create(sdf, "vmm", vmm_image);

    var guest = Vm.create(sdf, "linux");
    const guest_ram = Mr.create(sdf, "guest_ram", GUEST_RAM_SIZE, null, .large);
    sdf.addMemoryRegion(guest_ram);

    const guest_ram_map = Map.create(guest_ram, guestRamVaddr(board), .{ .read = true, .execute = true }, true, null);
    guest.addMap(guest_ram_map);

    // Then we add the virtual machine to the VMM
    const guest_ram_map_vmm = Map.create(guest_ram, guestRamVaddr(board), .{ .read = true }, true, null);
    vmm.addMap(guest_ram_map_vmm);
    try vmm.addVirtualMachine(guest);

    sdf.addProtectionDomain(vmm.*);

    // TODO: we have to do this here because otherwise we'll look everything on the stack.. yuck
    // This is something that ultimately needs to be fixed in sdf.zig
    const xml = try sdf.toXml();
    var xml_file = try std.fs.cwd().createFile(xml_out_path, .{});
    defer xml_file.close();
    _ = try xml_file.write(xml);
}

/// Takes in the root DTB node
/// TODO: there was an issue using the DTB that QEMU dumps. Most likely
/// something wrong with dtb.zig dependency. Need to investigate.
fn abstractions(_: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const image = ProgramImage.create("uart_driver.elf");
    const driver = Pd.create(sdf, "uart_driver", image);
    sdf.addProtectionDomain(driver.*);

    var uart_node: ?*dtb.Node = undefined;
    // TODO: We would probably want some helper functionality that just takes
    // the full node name such as "/soc/bus@ff8000000/serial@3000" and would
    // find the DTB node info that we need. For now, this fine.
    switch (board) {
        .odroidc4 => {
            const soc_node = blob.child("soc").?;
            const bus_node = soc_node.child("bus@ff800000").?;
            uart_node = bus_node.child("serial@3000");
        },
        .qemu_arm_virt => {
            uart_node = blob.child(board.uartNode());
        },
    }

    if (uart_node == null) {
        std.log.err("Could not find UART node '{s}'", .{board.uartNode()});
        std.process.exit(1);
    }

    // var serial_system = sddf.SerialSystem.init(allocator, sdf, 0x200000);
    // serial_system.setDriver(driver, uart_node.?);

    // const clients = [_][]const u8{ "client1", "client2", "client3" };

    const mux_rx_image = ProgramImage.create("mux_rx.elf");
    const mux_rx = Pd.create(sdf, "mux_rx", mux_rx_image);
    sdf.addProtectionDomain(mux_rx.*);

    const mux_tx_image = ProgramImage.create("mux_tx.elf");
    const mux_tx = Pd.create(sdf, "mux_tx", mux_tx_image);
    sdf.addProtectionDomain(mux_tx.*);

    // serial_system.setMultiplexors(mux_rx, mux_tx);

    const client1_image = ProgramImage.create("client1.elf");
    const client1_pd = Pd.create(sdf, "client1", client1_image);
    // serial_system.addClient(client1_pd.*);
    sdf.addProtectionDomain(client1_pd.*);

    const client2_image = ProgramImage.create("client2.elf");
    const client2_pd = Pd.create(sdf, "client2", client2_image);
    // serial_system.addClient(client2_pd.*);
    sdf.addProtectionDomain(client2_pd.*);

    // try serial_system.connect();

    const xml = try sdf.toXml();
    std.debug.print("{s}", .{xml});
}

fn gdb(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const uart_node = switch (board) {
        .odroidc4 => blob.child("soc").?.child("bus@ff800000").?.child("serial@3000"),
        .qemu_arm_virt => blob.child(board.uartNode()),
    };

    const uart_driver = Pd.create(sdf, "uart_driver", ProgramImage.create("uart_driver.elf"));
    std.debug.print("uart driver {*}\n", .{ uart_driver });
    sdf.addProtectionDomain(uart_driver.*);

    var serial_system = sddf.SerialSystem.init(allocator, sdf, 0x200000);
    serial_system.setDriver(uart_driver, uart_node.?);

    const debugger = Pd.create(sdf, "debugger", ProgramImage.create("debugger.elf"));
    std.debug.print("debugger {*}\n", .{ debugger });
    sdf.addProtectionDomain(debugger.*);

    const ping = Pd.create(sdf, "ping", ProgramImage.create("ping.elf"));
    const pong = Pd.create(sdf, "pong", ProgramImage.create("pong.elf"));

    const debug_pds = [_]*Pd{ ping, pong };
    for (debug_pds) |pd| {
        try debugger.addChild(pd.*);
    }

    sdf.addChannel(Channel.create(ping, pong));

    const mux_rx = Pd.create(sdf, "serial_mux_rx", ProgramImage.create("serial_mux_rx.elf"));
    sdf.addProtectionDomain(mux_rx.*);
    const mux_tx = Pd.create(sdf, "serial_mux_tx", ProgramImage.create("serial_mux_tx.elf"));
    sdf.addProtectionDomain(mux_tx.*);
    serial_system.setMultiplexors(mux_rx, mux_tx);

    std.debug.print("debugger name: {s}\n", .{ debugger.name });
    serial_system.addClient(debugger.*);

    try serial_system.connect();
    const xml = try sdf.toXml();
    std.debug.print("{s}", .{xml});

    const mux_rx_header = try sdf.exportCHeader(mux_rx);
    std.debug.print("{s}\n", .{ mux_rx_header });

    const debugger_header = try sdf.exportCHeader(debugger);
    std.debug.print("DEBUGGER HEADER:\n{s}\n", .{ debugger_header });
}

fn virtio_blk(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    // UART driver
    // serial muxes
    // two clients which as VMMs
    // block driver VM
    const image = ProgramImage.create("uart_driver.elf");
    const driver = Pd.create(sdf, "uart_driver", image);
    sdf.addProtectionDomain(driver.*);

    var uart_node: ?*dtb.Node = undefined;
    // TODO: We would probably want some helper functionality that just takes
    // the full node name such as "/soc/bus@ff8000000/serial@3000" and would
    // find the DTB node info that we need. For now, this fine.
    switch (board) {
        .odroidc4 => {
            const soc_node = blob.child("soc").?;
            const bus_node = soc_node.child("bus@ff800000").?;
            uart_node = bus_node.child("serial@3000");
        },
        .qemu_arm_virt => {
            uart_node = blob.child(board.uartNode());
        },
    }

    if (uart_node == null) {
        std.log.err("Could not find UART node '{s}'", .{board.uartNode()});
        std.process.exit(1);
    }

    const client1_vmm_image = ProgramImage.create("client_vmm_1.elf");
    const client1_vmm = Pd.create(sdf, "client_vmm_1", client1_vmm_image);
    const client1_vm = Vm.create(sdf, "client_vm_1");
    const client2_vmm_image = ProgramImage.create("client_vmm_2.elf");
    const client2_vmm = Pd.create(sdf, "client_vmm_2", client2_vmm_image);
    const client2_vm = Vm.create(sdf, "client_vm_2");

    const blk_driver_vmm_image = ProgramImage.create("blk_driver_vmm.elf");
    const blk_driver_vmm = Pd.create(sdf, "blk_driver_vmm", blk_driver_vmm_image);
    const blk_driver_vm = Vm.create(sdf, "blk_linux");

    var vm_system = VirtualMachineSystem.init(allocator, sdf);
    try vm_system.add(client1_vmm, client1_vm, blob);
    try vm_system.add(client2_vmm, client2_vm, blob);
    try vm_system.add(blk_driver_vmm, blk_driver_vm, blob);

    try vm_system.connect();

    // Creating serial sub system
    var serial_system = sddf.SerialSystem.init(allocator, sdf, 0x200000);
    serial_system.setDriver(driver, uart_node.?);

    const mux_rx_image = ProgramImage.create("mux_rx.elf");
    const mux_rx = Pd.create(sdf, "mux_rx", mux_rx_image);
    sdf.addProtectionDomain(mux_rx.*);

    const mux_tx_image = ProgramImage.create("mux_tx.elf");
    const mux_tx = Pd.create(sdf, "mux_tx", mux_tx_image);
    sdf.addProtectionDomain(mux_tx.*);

    serial_system.setMultiplexors(mux_rx, mux_tx);

    try serial_system.connect();

    const xml = try sdf.toXml();
    std.debug.print("{s}", .{xml});
}

fn kitty(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) !void {
    const uart_node = switch (board) {
        .odroidc4 => blob.child("soc").?.child("bus@ff800000").?.child("serial@3000"),
        .qemu_arm_virt => blob.child(board.uartNode()),
    };

    const uart_driver = Pd.create(sdf, "uart_driver", ProgramImage.create("uart_driver.elf"));
    sdf.addProtectionDomain(uart_driver.*);

    var serial_system = sddf.SerialSystem.init(allocator, sdf, 0x200000);
    serial_system.setDriver(uart_driver, uart_node.?);

    const mux_rx = Pd.create(sdf, "serial_mux_rx", ProgramImage.create("serial_mux_rx.elf"));
    sdf.addProtectionDomain(mux_rx.*);
    const mux_tx = Pd.create(sdf, "serial_mux_tx", ProgramImage.create("serial_mux_tx.elf"));
    sdf.addProtectionDomain(mux_tx.*);
    serial_system.setMultiplexors(mux_rx, mux_tx);

    const timer_node = switch (board) {
        .odroidc4 => blob.child("soc").?.child("bus@ffd00000").?.child("watchdog@f0d0").?,
        else => @panic("Don't know timer node for platform")
    };

    const timer_client = Pd.create(sdf, "timer_client", ProgramImage.create("timer_client.elf"));
    sdf.addProtectionDomain(timer_client.*);

    const timer_driver = Pd.create(sdf, "timer_driver", ProgramImage.create("timer_driver.elf"));
    sdf.addProtectionDomain(timer_driver.*);

    var timer_system = sddf.TimerSystem.init(allocator, sdf, timer_driver, timer_node);
    timer_system.addClient(timer_client);
    try timer_system.connect();

    // try serial_system.connect();
    const xml = try sdf.toXml();
    std.debug.print("{s}", .{xml});
}

pub fn main() !void {
    // An arena allocator makes much more sense for our purposes, all we're doing is doing a bunch
    // of allocations in a linear fashion and then just tearing everything down. This has better
    // performance than something like the General Purpose Allocator.
    // TODO: have a build argument that swaps the allocator.
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

    // Before doing any kind of XML generation we should probe sDDF for
    // configuration files etc
    try sddf.probe(allocator, sddf_path);

    const compatible_drivers = try sddf.compatibleDrivers(allocator);
    defer allocator.free(compatible_drivers);

    std.debug.print("sDDF drivers found:\n", .{});
    for (compatible_drivers) |driver| {
        std.debug.print("   - {s}\n", .{driver});
    }

    // Now that we have a list of compatible drivers, we need to find what actual
    // devices are available that are compatible. This will determine what IRQs
    // and memory regions are allocated for the driver. Each device will have separate
    // memory regions and interrupts needed.
    // My only worry here is that a driver does not necessarily *need* all the memory
    // that a device tree will specify. I think the same can be said of interrupts.
    // For now, and for simplicity, let's leave this as a problem to solve later. Right
    // now we will keep the device tree as the source of truth.

    var sdf = try SystemDescription.create(allocator, board.arch());
    try example.generate(allocator, &sdf, blob);
}
