const std = @import("std");

const mod_sdf = @import("sdf.zig");
const sddf = @import("sddf.zig");
const dtb = @import("dtb");

const Allocator = std.mem.Allocator;
const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Mr = SystemDescription.MemoryRegion;
const PageSize = Mr.PageSize;
const Vm = SystemDescription.VirtualMachine;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;
const DeviceTree = sddf.DeviceTree;

var board: MicrokitBoard = undefined;

const MicrokitBoard = enum {
    qemu_virt_aarch64,
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
            .qemu_virt_aarch64, .odroidc4 => .aarch64,
        };
    }

    /// Get the Device Tree node for the UART we want to use for
    /// each board
    pub fn uartNode(b: MicrokitBoard) []const u8 {
        return switch (b) {
            .qemu_virt_aarch64 => "pl011@9000000",
            .odroidc4 => "serial@3000",
        };
    }
};

fn parseVMFromJson(sdf: *SystemDescription, node_config: anytype) !*Vm {
    var vm_new = Vm.create(sdf.allocator, node_config.get("name").?.string, &.{.{ .id = 0, .cpu = 0 }});
    vm_new.budget = @intCast(node_config.get("budget").?.integer);
    vm_new.priority = @intCast(node_config.get("priority").?.integer);
    vm_new.period = @intCast(node_config.get("period").?.integer);

    const vm_copy = try sdf.allocator.create(Vm);
    vm_copy.* = vm_new;
    return vm_copy;
}

fn getMRByName(sdf: *SystemDescription, name: []const u8) !Mr {
    for (sdf.mrs.items) |mr| {
        if (std.mem.eql(u8, name, mr.name)) {
            return mr;
        }
    }
    return error.InvalidMrName;
}

fn parsePDFromJson(sdf: *SystemDescription, node_config: anytype) !*Pd {
    var pd_new = Pd.create(sdf.allocator, node_config.get("name").?.string, node_config.get("prog_img").?.string, .{
        .priority = @intCast(node_config.get("priority").?.integer),
        .budget = @intCast(node_config.get("budget").?.integer),
        .period = @intCast(node_config.get("period").?.integer),
    });
    // pp has been moved to channel
    // pd_new.pp = node_config.get("pp").?.bool;

    const children = node_config.get("children").?.array;
    var i: usize = 0;
    while (i < children.items.len) : (i += 1) {
        const child_config = children.items[i].object;
        const node_type = child_config.get("type").?.string;

        if (std.mem.eql(u8, node_type, "PD")) {
            const child_pd = parsePDFromJson(sdf, child_config) catch {
                return error.FailToParsePD;
            };
            pd_new.addChild(child_pd) catch |err| {
                return err;
            };
        } else if (std.mem.eql(u8, node_type, "VM")) {
            const child_vm = parseVMFromJson(sdf, child_config) catch {
                return error.FailToParseVM;
            };
            pd_new.setVirtualMachine(child_vm) catch |err| {
                return err;
            };
        }
    }

    const map_configs = node_config.get("maps").?.array;
    i = 0;
    while (i < map_configs.items.len) : (i += 1) {
        const map_config = map_configs.items[i].object;
        const map_new = parseMapFromJson(sdf, map_config) catch |err| {
            return err;
        };
        pd_new.addMap(map_new);
    }

    const irq_configs = node_config.get("irqs").?.array;
    i = 0;
    while (i < irq_configs.items.len) : (i += 1) {
        const irq_config = irq_configs.items[i].object;
        const irq_new = parseIrqFromJson(irq_config) catch |err| {
            return err;
        };
        pd_new.addIrq(irq_new) catch |err| {
            return err;
        };
    }

    const pd_copy = try sdf.allocator.create(Pd);

    pd_copy.* = pd_new;
    return pd_copy;
}

fn parseChannelFromJson(sdf: *SystemDescription, channel_config: anytype) !Channel {
    const pd1_name = channel_config.get("pd1").?.string;
    const pd2_name = channel_config.get("pd2").?.string;
    const pd1 = if (sdf.findPd(pd1_name)) |pd| pd else return error.PdCannotBeFound;
    const pd2 = if (sdf.findPd(pd2_name)) |pd| pd else return error.PdCannotBeFound;

    var channel_new = Channel.create(pd1, pd2, .{});
    channel_new.pd_a_id = @intCast(channel_config.get("pd1_end_id").?.integer);
    channel_new.pd_b_id = @intCast(channel_config.get("pd2_end_id").?.integer);

    return channel_new;
}

fn parseMRFromJson(sdf: *SystemDescription, mr_config: anytype) !Mr {
    const name = mr_config.get("name").?.string;

    const size: usize = @intCast(mr_config.get("size").?.integer);
    // const phys_addr: usize = @intCast(mr_config.get("phys_addr").?.integer);
    var phys_addr: ?usize = null;
    if (mr_config.get("phys_addr")) |phys_addr_json| {
        switch (phys_addr_json) {
            .integer => {
                phys_addr = @intCast(phys_addr_json.integer);
            },
            .null => {},
            else => @panic("Invalid phys_addr JSON"),
        }
    }
    // const page_size: Mr.PageSize = @intCast(mr_config.get("page_size").?.integer);
    const mr_new = Mr.create(sdf.allocator, name, size, true, .{});

    return mr_new;
}

fn parseIrqFromJson(irq_config: anytype) !Irq {
    const irq_num: usize = @intCast(irq_config.get("irq").?.integer);
    const id: usize = @intCast(irq_config.get("id_").?.integer);
    const trigger_str = irq_config.get("trigger").?.string;
    var trigger: Irq.Trigger = .edge;
    if (std.mem.eql(u8, trigger_str, "level")) {
        trigger = .level;
    } else if (std.mem.eql(u8, trigger_str, "edge")) {
        trigger = .edge;
    } else {
        return error.InvalidTrigger;
    }
    const irq_new = Irq.create(irq_num, trigger, id);
    return irq_new;
}

fn parseMapFromJson(sdf: *SystemDescription, map_config: anytype) !Map {
    const mr = getMRByName(sdf, map_config.get("mr").?.string) catch |err| {
        return err;
    };

    const vaddr: usize = @intCast(map_config.get("vaddr").?.integer);
    const perm_r = map_config.get("perm_r").?.bool;
    const perm_w = map_config.get("perm_w").?.bool;
    const perm_x = map_config.get("perm_x").?.bool;
    const cached = map_config.get("cached").?.bool;
    var setvar_vaddr: ?[]const u8 = null;
    if (map_config.get("setvar_vaddr")) |setvar_vaddr_json| {
        switch (setvar_vaddr_json) {
            .string => {
                setvar_vaddr = setvar_vaddr_json.string;
            },
            .null => {},
            else => @panic("Invalid setvar_vaddr JSON"),
        }
    }

    const map = Map.create(mr, vaddr, .{ .read = perm_r, .write = perm_w, .execute = perm_x }, cached, .{ .setvar_vaddr = setvar_vaddr });
    return map;
}

fn parseSddfSubsystemFromJson(sdf: *SystemDescription, subsystem_config: anytype, blob: *dtb.Node) !void {
    const class = subsystem_config.get("class").?.string;
    const driver_name = subsystem_config.get("driver_name").?.string;
    const mux_tx_name = subsystem_config.get("serial_mux_tx").?.string;
    const mux_rx_name = subsystem_config.get("serial_mux_rx").?.string;

    if (std.mem.eql(u8, class, "serial")) {
        const clients = subsystem_config.get("clients").?.array;
        if (clients.items.len != 2) {
            return;
        }
        const client1_name = clients.items[0].string;
        const client2_name = clients.items[1].string;

        var uart_node: ?*dtb.Node = undefined;
        switch (board) {
            .odroidc4 => {
                const soc_node = blob.child("soc").?;
                const bus_node = soc_node.child("bus@ff800000").?;
                uart_node = bus_node.child("serial@3000");
            },
            .qemu_virt_aarch64 => {
                uart_node = blob.child(board.uartNode());
            },
        }
        const driver = if (sdf.findPd(driver_name)) |pd| pd else return error.PdCannotBeFound;
        const mux_tx = if (sdf.findPd(mux_tx_name)) |pd| pd else return error.PdCannotBeFound;
        const mux_rx = if (sdf.findPd(mux_rx_name)) |pd| pd else return error.PdCannotBeFound;

        var serial_system = sddf.SerialSystem.init(sdf.allocator, sdf, uart_node.?, driver, mux_tx, mux_rx, .{}) catch {
            return error.FailedToCreateSerialSystem;
        };

        const client1_pd = if (sdf.findPd(client1_name)) |pd| pd else return error.PdCannotBeFound;
        const client2_pd = if (sdf.findPd(client2_name)) |pd| pd else return error.PdCannotBeFound;

        serial_system.addClient(client1_pd);
        serial_system.addClient(client2_pd);
        serial_system.connect() catch {
            return error.ConnectError;
        };
    }
}

fn parseAndBuild(sdf: *SystemDescription, json: anytype, blob: *dtb.Node) ![]const u8 {
    const pds = json.get("pds").?.array;
    const channels = json.get("channels").?.array;
    const mrs = json.get("mrs").?.array;
    const sddf_subsystems = json.get("sddf_subsystems").?.array;

    var i: usize = 0;
    while (i < mrs.items.len) : (i += 1) {
        const mr_config = mrs.items[i].object;

        const mr_new = parseMRFromJson(sdf, mr_config) catch {
            return "Failed to parse MR";
        };
        sdf.addMemoryRegion(mr_new);
    }

    i = 0;
    while (i < pds.items.len) : (i += 1) {
        const pd_config = pds.items[i].object;

        const pd_new = parsePDFromJson(sdf, pd_config) catch {
            return "Failed to parse PD";
        };
        sdf.addProtectionDomain(pd_new);
    }

    i = 0;
    while (i < channels.items.len) : (i += 1) {
        const channel_config = channels.items[i].object;

        const channel_new = parseChannelFromJson(sdf, channel_config) catch {
            return "Failed to parse Channel";
        };
        sdf.addChannel(channel_new);
    }

    i = 0;
    while (i < sddf_subsystems.items.len) : (i += 1) {
        const subsystem_config = sddf_subsystems.items[i].object;

        parseSddfSubsystemFromJson(sdf, subsystem_config, blob) catch {
            return "Failed to parse sddf_subsystem";
        };
    }

    const xml = sdf.toXml();
    return xml;
}

fn printMsg(result_ptr: [*]u8, msg: []const u8) usize {
    std.mem.copyForwards(u8, result_ptr[0..msg.len], msg);
    return msg.len;
}

export fn jsonToXml(input_ptr: [*]const u8, input_len: usize, result_ptr: [*]u8) usize {
    const input = input_ptr[0..input_len];

    const allocator = std.heap.wasm_allocator;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        return 1;
    };
    defer parsed.deinit();

    const object = parsed.value.object;

    // Check that path to DTB exists
    const board_str = object.get("board").?.string;
    board = MicrokitBoard.fromStr(board_str) catch {
        return printMsg(result_ptr, "Failed to read board");
    };

    const blob_bytes = object.get("dtb").?.array;

    // We take the 64-bit integer array of the DTB from JS and convert it to an
    // array of bytes.
    var dtb_bytes = std.ArrayList(u8).initCapacity(allocator, blob_bytes.items.len + 1) catch {
        return printMsg(result_ptr, "Failed to allocate memory for DTB bytes");
    };
    defer dtb_bytes.deinit();
    var i: usize = 0;
    while (i < blob_bytes.items.len) : (i += 1) {
        dtb_bytes.append(@intCast(blob_bytes.items[i].integer)) catch {
            return printMsg(result_ptr, "Failed to read DTB bytes");
        };
    }

    // Add final terminal byte
    dtb_bytes.append(0) catch {
        return 202;
    };

    var blob = dtb.parse(allocator, dtb_bytes.items) catch {
        return printMsg(result_ptr, "DTB parsing error");
    };
    defer blob.deinit(allocator);

    var sdf = SystemDescription.create(allocator, board.arch(), 0x100_000_000);
    defer sdf.destroy();

    const drivers = object.get("drivers").?.array;
    const classes = object.get("deviceClasses").?.array;
    sddf.wasmProbe(allocator, drivers, classes) catch {
        return printMsg(result_ptr, "Failed to probe sDDF");
    };
    const compatible_drivers = sddf.compatibleDrivers(allocator) catch {
        return printMsg(result_ptr, "Failed to find compatible drivers");
    };
    defer allocator.free(compatible_drivers);

    const xml = parseAndBuild(&sdf, object, blob) catch {
        return printMsg(result_ptr, "Failed to parse the attributes!");
    };

    return printMsg(result_ptr, xml);
}

fn getDtJson(allocator: Allocator, blob: *dtb.Node, writer: anytype) !void {
    _ = try writer.write("{");
    const json_string = try std.fmt.allocPrint(allocator, "\"name\":\"{s}\",\"compatibles\":", .{blob.name});
    defer allocator.free(json_string);
    _ = try writer.write(json_string);

    _ = try writer.write("[");
    if (blob.prop(.Compatible)) |compatibles| {
        for (compatibles, 0..) |compatible, i| {
            if (i != 0) {
                _ = try writer.write(", ");
            }
            const compatible_string = try std.fmt.allocPrint(allocator, "\"{s}\"", .{compatible});
            defer allocator.free(compatible_string);
            _ = try writer.write(compatible_string);
        }
    }
    _ = try writer.write("]");

    if (blob.children.len == 0) {
        if (blob.prop(.Interrupts)) |interrupts| {
            if (interrupts.len == 1 and interrupts[0].len == 3) {
                _ = try writer.write(", \"irq\":{");
                const irq_type = try DeviceTree.armGicIrqType(interrupts[0][0]);
                const irq_number = DeviceTree.armGicIrqNumber(interrupts[0][1], irq_type);

                const irq_string = try std.fmt.allocPrint(allocator, "\"irq_number\": {any}, \"irq_trigger\": {any}", .{ irq_number, interrupts[0][2] });
                defer allocator.free(irq_string);
                _ = try writer.write(irq_string);

                _ = try writer.write("}");
            }
        }
    }

    _ = try writer.write(",\"children\":[");
    for (blob.children, 0..) |child, i| {
        if (i != 0) {
            _ = try writer.write(", ");
        }
        getDtJson(allocator, child, writer) catch |err| {
            return err;
        };
    }
    _ = try writer.write("]}");
}

const BoardInfo = struct {
    const BoardPageSize = struct {
        label: []const u8,
        value: u32,
    };

    // const DeviceTreeIrq = struct {
    //     number: u32,
    //     trigger: []const u8,
    // };

    const DeviceTreeNode = struct {
        name: []const u8,
        compatibles: [][]const u8,
        children: []DeviceTreeNode,
        // irq: ?DeviceTreeIrq,
    };

    page_size: []const BoardPageSize,
    device_tree: DeviceTreeNode,
};

export fn fetchInitInfo(input_ptr: [*]const u8, input_len: usize, result_ptr: [*]u8) usize {
    const input = input_ptr[0..input_len];
    const allocator = std.heap.wasm_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        return printMsg(result_ptr, "Invalid JSON string!");
    };
    defer parsed.deinit();

    const object = parsed.value.object;
    const blob_bytes = object.get("dtb").?.array;

    // We take the 64-bit integer array of the DTB from JS and convert it to an
    // array of bytes.
    var dtb_bytes = std.ArrayList(u8).initCapacity(allocator, blob_bytes.items.len + 1) catch {
        return printMsg(result_ptr, "Failed to allocate memory for DTB bytes");
    };
    defer dtb_bytes.deinit();
    var i: usize = 0;
    while (i < blob_bytes.items.len) : (i += 1) {
        dtb_bytes.append(@intCast(blob_bytes.items[i].integer)) catch {
            return printMsg(result_ptr, "Failed to read DTB bytes");
        };
    }

    // Add final terminal byte
    dtb_bytes.append(0) catch {
        return 202;
    };

    const blob = dtb.parse(allocator, dtb_bytes.items) catch {
        return printMsg(result_ptr, "DTB parsing error");
    };
    defer blob.deinit(allocator);

    const board_info = BoardInfo{
        // TODO: don't hardcode
        .page_size = &[_]BoardInfo.BoardPageSize{
            .{ .label = "small", .value = 0x1000 },
            .{ .label = "large", .value = 0x200_000 },
        },
        .device_tree = .{
            .name = "root",
            .compatibles = &.{},
            .children = &.{},
        },
    };

    var board_info_json = std.ArrayList(u8).init(allocator);
    defer board_info_json.deinit();

    // TODO: properly handle OOM
    std.json.stringify(board_info, .{}, board_info_json.writer()) catch @panic("OOM");

    return printMsg(result_ptr, board_info_json.items[0..board_info_json.items.len]);
}
