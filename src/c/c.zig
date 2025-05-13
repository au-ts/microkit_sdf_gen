const std = @import("std");
const modsdf = @import("sdf");
const log = modsdf.log;
// Because this is intended to be used in the context of C, we always
// use the C allocator, even though it might not be the most efficient.
const allocator = std.heap.c_allocator;

const bindings = @cImport({
    @cInclude("sdfgen.h");
});

const dtb = modsdf.dtb;
const sddf = modsdf.sddf;
const lionsos = modsdf.lionsos;
const Vmm = modsdf.Vmm;
const SystemDescription = modsdf.sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Irq = SystemDescription.Irq;
const Vm = SystemDescription.VirtualMachine;
const Channel = SystemDescription.Channel;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Arch = SystemDescription.Arch;

// TODO: handle passing options to sDDF systems

export fn sdfgen_create(c_arch: bindings.sdfgen_arch_t, paddr_top: u64) *anyopaque {
    const arch: Arch = @enumFromInt(c_arch);
    // Double check that there is a one-to-one mapping between the architecture for
    // the C enum and the Zig enum.
    switch (arch) {
        .aarch32 => std.debug.assert(c_arch == 0),
        .aarch64 => std.debug.assert(c_arch == 1),
        .riscv32 => std.debug.assert(c_arch == 2),
        .riscv64 => std.debug.assert(c_arch == 3),
        .x86 => std.debug.assert(c_arch == 4),
        .x86_64 => std.debug.assert(c_arch == 5),
    }
    const sdf = allocator.create(SystemDescription) catch @panic("OOM");
    sdf.* = SystemDescription.create(allocator, arch, paddr_top);

    return sdf;
}

export fn sdfgen_destroy(c_sdf: *align(8) anyopaque) void {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    sdf.destroy();
}

export fn sdfgen_add_pd(c_sdf: *align(8) anyopaque, c_pd: *align(8) anyopaque) void {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    sdf.addProtectionDomain(@ptrCast(c_pd));
}

export fn sdfgen_add_mr(c_sdf: *align(8) anyopaque, c_mr: *align(8) anyopaque) void {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const mr: *Mr = @ptrCast(c_mr);
    sdf.addMemoryRegion(mr.*);
}

export fn sdfgen_add_channel(c_sdf: *align(8) anyopaque, c_ch: *align(8) anyopaque) void {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const ch: *Channel = @ptrCast(c_ch);
    sdf.addChannel(ch.*);
}

export fn sdfgen_render(c_sdf: *align(8) anyopaque) [*c]u8 {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const rendered = sdf.render() catch @panic("Cannot convert to XML");
    return @constCast(rendered);
}

export fn sdfgen_dtb_parse(path: [*c]u8) ?*anyopaque {
    const file = std.fs.cwd().openFile(std.mem.span(path), .{}) catch |e| {
        log.err("could not open DTB '{s}' for parsing with error: {any}", .{ path, e });
        return null;
    };
    const stat = file.stat() catch |e| {
        log.err("could not stat DTB '{s}' for parsing with error: {any}", .{ path, e });
        return null;
    };
    const bytes = file.reader().readAllAlloc(allocator, @intCast(stat.size)) catch |e| {
        log.err("could not read DTB '{s}' for parsing with error: {any}", .{ path, e });
        return null;
    };
    const blob = modsdf.dtb.parse(allocator, bytes) catch |e| {
        log.err("could not parse DTB '{s}' with error: {any}", .{ path, e });
        return null;
    };

    return blob;
}

export fn sdfgen_dtb_parse_from_bytes(bytes: [*c]u8, size: u32) ?*anyopaque {
    const blob = modsdf.dtb.parse(allocator, bytes[0..size]) catch |e| {
        log.err("could not parse DTB from bytes with error: {any}", .{e});
        return null;
    };

    return blob;
}

export fn sdfgen_dtb_node(c_blob: *align(8) anyopaque, c_node: [*c]u8) ?*anyopaque {
    const blob: *dtb.Node = @ptrCast(c_blob);
    const node = std.mem.span(c_node);
    var it = std.mem.splitSequence(u8, node, "/");
    var curr_node: *dtb.Node = blob;
    while (it.next()) |n| {
        if (curr_node.child(n)) |child| {
            curr_node = child;
        } else {
            return null;
        }
    }

    return curr_node;
}

export fn sdfgen_dtb_destroy(c_blob: *align(8) anyopaque) void {
    const blob: *dtb.Node = @ptrCast(c_blob);
    blob.deinit(allocator);
}

export fn sdfgen_pd_create(name: [*c]u8, program_image: [*c]u8) *anyopaque {
    const pd = allocator.create(Pd) catch @panic("OOM");
    pd.* = Pd.create(allocator, std.mem.span(name), std.mem.span(program_image), .{});

    return pd;
}

export fn sdfgen_pd_destroy(c_pd: *align(8) anyopaque) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.destroy();
    allocator.destroy(pd);
}

export fn sdfgen_pd_add_child(c_pd: *align(8) anyopaque, c_child_pd: *align(8) anyopaque, c_child_id: ?*u8) i8 {
    const pd: *Pd = @ptrCast(c_pd);
    const child_pd: *Pd = @ptrCast(c_child_pd);
    const child_id = if (c_child_id) |c| c.* else null;

    const id = pd.addChild(child_pd, .{ .id = child_id }) catch |e| {
        log.err("failed to add child '{s}' to parent '{s}': {any}", .{ child_pd.name, pd.name, e });
        return -1;
    };

    return @intCast(id);
}

export fn sdfgen_pd_add_map(c_pd: *align(8) anyopaque, c_map: *align(8) anyopaque) void {
    const pd: *Pd = @ptrCast(c_pd);
    const map: *Map = @ptrCast(c_map);

    pd.addMap(map.*);
}

export fn sdfgen_pd_add_irq(c_pd: *align(8) anyopaque, c_irq: *align(8) anyopaque) i8 {
    const pd: *Pd = @ptrCast(c_pd);
    const irq: *Irq = @ptrCast(c_irq);

    const id = pd.addIrq(irq.*) catch |e| {
        log.err("failed to add IRQ '{}' to PD '{s}': {}", .{ irq.irq, pd.name, e });
        return -1;
    };

    return @intCast(id);
}

export fn sdfgen_pd_set_priority(c_pd: *align(8) anyopaque, priority: u8) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.priority = priority;
}

export fn sdfgen_pd_set_budget(c_pd: *align(8) anyopaque, budget: u32) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.budget = budget;
}

export fn sdfgen_pd_set_period(c_pd: *align(8) anyopaque, period: u32) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.period = period;
}

export fn sdfgen_pd_set_stack_size(c_pd: *align(8) anyopaque, stack_size: u32) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.stack_size = stack_size;
}

export fn sdfgen_pd_set_cpu(c_pd: *align(8) anyopaque, cpu: u8) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.cpu = cpu;
}

export fn sdfgen_pd_set_passive(c_pd: *align(8) anyopaque, passive: bool) void {
    const pd: *Pd = @ptrCast(c_pd);
    pd.passive = passive;
}

export fn sdfgen_pd_set_virtual_machine(c_pd: *align(8) anyopaque, c_vm: *align(8) anyopaque) bool {
    const pd: *Pd = @ptrCast(c_pd);
    const vm: *Vm = @ptrCast(c_vm);
    pd.setVirtualMachine(vm) catch return false;

    return true;
}

export fn sdfgen_vm_create(name: [*c]u8, c_vcpus: [*c]*align(8) anyopaque, num_vcpus: u32) ?*anyopaque {
    var vcpus = std.ArrayList(Vm.Vcpu).initCapacity(allocator, num_vcpus) catch @panic("OOM");
    defer vcpus.deinit();

    var i: usize = 0;
    while (i < num_vcpus) : (i += 1) {
        const vcpu: *Vm.Vcpu = @ptrCast(c_vcpus[i]);
        vcpus.appendAssumeCapacity(vcpu.*);
    }

    const vm = allocator.create(Vm) catch @panic("OOM");
    vm.* = Vm.create(allocator, std.mem.span(name), vcpus.items, .{}) catch |e| {
        log.err("falied to create VM '{s}': {any}", .{ name, e });
        return null;
    };

    return vm;
}

export fn sdfgen_vm_destroy(c_vm: *align(8) anyopaque) void {
    const vm: *Vm = @ptrCast(c_vm);
    vm.destroy();
    allocator.destroy(vm);
}

export fn sdfgen_vm_set_priority(c_vm: *align(8) anyopaque, priority: u8) void {
    const vm: *Vm = @ptrCast(c_vm);
    vm.priority = priority;
}

export fn sdfgen_vm_set_budget(c_vm: *align(8) anyopaque, budget: u32) void {
    const vm: *Pd = @ptrCast(c_vm);
    vm.budget = budget;
}

export fn sdfgen_vm_set_period(c_vm: *align(8) anyopaque, period: u32) void {
    const vm: *Pd = @ptrCast(c_vm);
    vm.period = period;
}

export fn sdfgen_vm_vcpu_create(id: u8, cpu: [*c]u8) *anyopaque {
    const vcpu: *Vm.Vcpu = allocator.create(Vm.Vcpu) catch @panic("OOM");
    vcpu.* = Vm.Vcpu{ .id = id };
    if (cpu != null) {
        vcpu.cpu = cpu.*;
    }

    return vcpu;
}

export fn sdfgen_vm_vcpu_destroy(c_vcpu: *align(8) anyopaque) void {
    const vcpu: *Vm.Vcpu = @ptrCast(c_vcpu);
    allocator.destroy(vcpu);
}

export fn sdfgen_vm_add_map(c_vm: *align(8) anyopaque, c_map: *align(8) anyopaque) void {
    const vm: *Vm = @ptrCast(c_vm);
    const map: *Map = @ptrCast(c_map);
    vm.addMap(map.*);
}

export fn sdfgen_sddf_init(path: [*c]u8) bool {
    sddf.probe(allocator, std.mem.span(path)) catch |e| {
        log.err("sDDF init failed on path {s}: {}", .{ path, e });
        return false;
    };

    return true;
}

export fn sdfgen_irq_create(number: u32, c_trigger: [*c]bindings.sdfgen_irq_trigger_t, c_id: [*c]u8) ?*anyopaque {
    const irq = allocator.create(Irq) catch @panic("OOM");
    var options: Irq.Options = .{};
    if (c_trigger != null) {
        const trigger: Irq.Trigger = switch (c_trigger.*) {
            0 => .edge,
            1 => .level,
            else => {
                log.err("failed to create IRQ '{}': invalid trigger '{}'", .{ number, c_trigger.* });
                return null;
            },
        };
        options.trigger = trigger;
    }
    if (c_id != null) {
        options.id = c_id.*;
    }

    irq.* = Irq.create(number, options);

    return irq;
}

export fn sdfgen_irq_destroy(c_irq: *align(8) anyopaque) void {
    const irq: *Irq = @ptrCast(c_irq);
    allocator.destroy(irq);
}

export fn sdfgen_mr_create(name: [*c]u8, size: u64) *anyopaque {
    const mr = allocator.create(Mr) catch @panic("OOM");
    mr.* = Mr.create(allocator, std.mem.span(name), size, .{});

    return mr;
}

export fn sdfgen_mr_create_physical(name: [*c]u8, size: u64, paddr: u64) *anyopaque {
    const mr = allocator.create(Mr) catch @panic("OOM");
    mr.* = Mr.create(allocator, std.mem.span(name), size, .{});
    mr.paddr = paddr;

    return mr;
}

export fn sdfgen_mr_get_paddr(c_mr: *align(8) anyopaque, paddr: *u64) bool {
    const mr: *Mr = @ptrCast(c_mr);
    if (mr.paddr) |paddr_val| {
        paddr.* = paddr_val;
    }
    return mr.paddr != null;
}

export fn sdfgen_mr_destroy(c_mr: *align(8) anyopaque) void {
    const mr: *Mr = @ptrCast(c_mr);
    allocator.destroy(mr);
}

export fn sdfgen_map_create(c_mr: *align(8) anyopaque, vaddr: u64, c_perms: bindings.sdfgen_map_perms_t, cached: bool) ?*anyopaque {
    const mr: *Mr = @ptrCast(c_mr);

    var perms: Map.Perms = .{};
    if (c_perms & 0b001 != 0) {
        perms.read = true;
    }
    if (c_perms & 0b010 != 0) {
        perms.write = true;
    }
    if (c_perms & 0b100 != 0) {
        perms.execute = true;
    }

    const map = allocator.create(Map) catch @panic("OOM");
    // TODO: I think we got some memory problems if we're dereferencing this stuff since
    // we need MemoryRegion to still be valid the whole time since we depend on it
    map.* = Map.create(mr.*, vaddr, perms, .{ .cached = cached });

    return map;
}

export fn sdfgen_map_destroy(c_map: *align(8) anyopaque) void {
    const map: *Map = @ptrCast(c_map);
    allocator.destroy(map);
}

export fn sdfgen_channel_create(c_pd_a: *align(8) anyopaque, c_pd_b: *align(8) anyopaque, pd_a_id: [*c]u8, pd_b_id: [*c]u8, pd_a_notify: [*c]bool, pd_b_notify: [*c]bool, c_pp: [*c]u8) ?*anyopaque {
    const pd_a: *Pd = @ptrCast(c_pd_a);
    const pd_b: *Pd = @ptrCast(c_pd_b);

    var options: Channel.Options = .{};
    if (pd_a_id != null) {
        options.pd_a_id = pd_a_id.*;
    }
    if (pd_b_id != null) {
        options.pd_b_id = pd_b_id.*;
    }
    if (pd_a_notify != null) {
        options.pd_a_notify = pd_a_notify.*;
    }
    if (pd_b_notify != null) {
        options.pd_b_notify = pd_b_notify.*;
    }
    if (c_pp != null) {
        const pp: Channel.End = switch (c_pp.*) {
            0 => .a,
            1 => .b,
            else => {
                log.err("failed to create channel between '{s}' and '{s}': invalid pp option given '{}'", .{ pd_a.name, pd_b.name, c_pp.* });
                return null;
            },
        };
        options.pp = pp;
    }

    const ch = allocator.create(Channel) catch @panic("OOM");
    ch.* = Channel.create(pd_a, pd_b, options) catch |e| {
        log.err("failed to create channel between '{s}' and '{s}': {any}", .{ pd_a.name, pd_b.name, e });
        return null;
    };

    return ch;
}

export fn sdfgen_channel_get_pd_a_id(c_ch: *align(8) anyopaque) u8 {
    const ch: *Channel = @ptrCast(c_ch);
    return ch.pd_a_id;
}

export fn sdfgen_channel_get_pd_b_id(c_ch: *align(8) anyopaque) u8 {
    const ch: *Channel = @ptrCast(c_ch);
    return ch.pd_b_id;
}

export fn sdfgen_channel_destroy(c_ch: *align(8) anyopaque) void {
    const ch: *Channel = @ptrCast(c_ch);
    allocator.destroy(ch);
}

export fn sdfgen_channel_add(c_sdf: *align(8) anyopaque, c_ch: *align(8) anyopaque) void {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const ch: *Channel = @ptrCast(c_ch);
    sdf.addChannel(ch.*);
}

export fn sdfgen_sddf_timer(c_sdf: *align(8) anyopaque, c_device: ?*align(8) anyopaque, driver: *align(8) anyopaque) *anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const timer = allocator.create(sddf.Timer) catch @panic("OOM");
    timer.* = sddf.Timer.init(allocator, sdf, @ptrCast(c_device), @ptrCast(driver));

    return timer;
}

export fn sdfgen_sddf_timer_destroy(system: *align(8) anyopaque) void {
    const timer: *sddf.Timer = @ptrCast(system);
    timer.deinit();
    allocator.destroy(timer);
}

export fn sdfgen_sddf_timer_add_client(system: *align(8) anyopaque, client: *align(8) anyopaque) bindings.sdfgen_sddf_status_t {
    const timer: *sddf.Timer = @ptrCast(system);
    timer.addClient(@ptrCast(client)) catch |e| {
        switch (e) {
            sddf.Timer.Error.DuplicateClient => return 1,
            sddf.Timer.Error.InvalidClient => return 2,
            // Should never happen when adding a client
            sddf.Timer.Error.NotConnected => @panic("internal error"),
        }
    };

    return 0;
}

export fn sdfgen_sddf_timer_connect(system: *align(8) anyopaque) bool {
    const timer: *sddf.Timer = @ptrCast(system);
    timer.connect() catch return false;

    return true;
}

export fn sdfgen_sddf_timer_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const timer: *sddf.Timer = @ptrCast(system);
    timer.serialiseConfig(std.mem.span(output_dir)) catch return false;

    return true;
}

export fn sdfgen_sddf_serial(c_sdf: *align(8) anyopaque, c_device: ?*align(8) anyopaque, driver: *align(8) anyopaque, virt_tx: *align(8) anyopaque, virt_rx: ?*align(8) anyopaque, enable_color: bool, begin_str: [*c]u8) ?*anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const device: *dtb.Node = @ptrCast(c_device);
    var options: sddf.Serial.Options = .{
        .virt_rx = @ptrCast(virt_rx),
        .enable_color = enable_color,
    };
    if (begin_str != null) {
        options.begin_str = std.mem.span(begin_str);
    }
    const serial = allocator.create(sddf.Serial) catch @panic("OOM");
    serial.* = sddf.Serial.init(allocator, sdf, device, @ptrCast(driver), @ptrCast(virt_tx), options) catch |e| {
        log.err("failed to initialiase serial system for device '{s}': {any}", .{ device.name, e });
        allocator.destroy(serial);
        return null;
    };

    return serial;
}

export fn sdfgen_sddf_serial_destroy(system: *align(8) anyopaque) void {
    const serial: *sddf.Serial = @ptrCast(system);
    serial.deinit();
    allocator.destroy(serial);
}

export fn sdfgen_sddf_serial_add_client(system: *align(8) anyopaque, client: *align(8) anyopaque) bindings.sdfgen_sddf_status_t {
    const serial: *sddf.Serial = @ptrCast(system);
    serial.addClient(@ptrCast(client)) catch |e| {
        switch (e) {
            sddf.Serial.Error.DuplicateClient => return 1,
            sddf.Serial.Error.InvalidClient => return 2,
            // Should never happen when adding a client
            sddf.Serial.Error.InvalidBeginString, sddf.Serial.Error.InvalidVirt, sddf.Serial.Error.NotConnected => @panic("internal error"),
        }
    };

    return 0;
}

export fn sdfgen_sddf_serial_connect(system: *align(8) anyopaque) bool {
    const serial: *sddf.Serial = @ptrCast(system);
    serial.connect() catch return false;

    return true;
}

export fn sdfgen_sddf_serial_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const serial: *sddf.Serial = @ptrCast(system);
    serial.serialiseConfig(std.mem.span(output_dir)) catch return false;
    return true;
}

export fn sdfgen_sddf_i2c(c_sdf: *align(8) anyopaque, c_device: ?*align(8) anyopaque, driver: *align(8) anyopaque, virt: *align(8) anyopaque) *anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const i2c = allocator.create(sddf.I2c) catch @panic("OOM");
    i2c.* = sddf.I2c.init(allocator, sdf, @ptrCast(c_device), @ptrCast(driver), @ptrCast(virt), .{});

    return i2c;
}

export fn sdfgen_sddf_i2c_destroy(system: *align(8) anyopaque) void {
    const i2c: *sddf.I2c = @ptrCast(system);
    i2c.deinit();
    allocator.destroy(i2c);
}

export fn sdfgen_sddf_i2c_add_client(system: *align(8) anyopaque, client: *align(8) anyopaque) bindings.sdfgen_sddf_status_t {
    const i2c: *sddf.I2c = @ptrCast(system);
    i2c.addClient(@ptrCast(client)) catch |e| {
        switch (e) {
            sddf.I2c.Error.DuplicateClient => return 1,
            sddf.I2c.Error.InvalidClient => return 2,
            // Should never happen when adding a client
            sddf.I2c.Error.NotConnected => @panic("internal error"),
        }
    };

    return 0;
}

export fn sdfgen_sddf_i2c_connect(system: *align(8) anyopaque) bool {
    const i2c: *sddf.I2c = @ptrCast(system);
    i2c.connect() catch return false;

    return true;
}

export fn sdfgen_sddf_i2c_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const i2c: *sddf.I2c = @ptrCast(system);
    i2c.serialiseConfig(std.mem.span(output_dir)) catch return false;
    return true;
}

export fn sdfgen_sddf_blk(c_sdf: *align(8) anyopaque, c_device: *align(8) anyopaque, driver: *align(8) anyopaque, virt: *align(8) anyopaque) ?*anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const device: *dtb.Node = @ptrCast(c_device);
    const blk = allocator.create(sddf.Blk) catch @panic("OOM");
    blk.* = sddf.Blk.init(allocator, sdf, device, @ptrCast(driver), @ptrCast(virt), .{}) catch |e| {
        log.err("failed to initialiase blk system for device '{s}': {any}", .{ device.name, e });
        allocator.destroy(blk);
        return null;
    };

    return blk;
}

export fn sdfgen_sddf_blk_destroy(system: *align(8) anyopaque) void {
    const blk: *sddf.Blk = @ptrCast(system);
    blk.deinit();
    allocator.destroy(blk);
}

export fn sdfgen_sddf_blk_add_client(system: *align(8) anyopaque, client: *align(8) anyopaque, partition: u32, queue_capacity: [*c]u16, data_size: [*c]u32) bindings.sdfgen_sddf_status_t {
    var options: sddf.Blk.ClientOptions = .{
        .partition = partition,
    };
    if (queue_capacity != null) {
        options.queue_capacity = queue_capacity.*;
    }
    if (data_size != null) {
        options.data_size = data_size.*;
    }

    const blk: *sddf.Blk = @ptrCast(system);
    blk.addClient(@ptrCast(client), options) catch |e| {
        switch (e) {
            sddf.Blk.Error.DuplicateClient => return 1,
            sddf.Blk.Error.InvalidClient => return 2,
            // Should never happen when adding a client
            sddf.Blk.Error.InvalidVirt, sddf.Blk.Error.NotConnected => @panic("internal error"),
        }
    };

    return 0;
}

export fn sdfgen_sddf_blk_connect(system: *align(8) anyopaque) bool {
    const blk: *sddf.Blk = @ptrCast(system);
    blk.connect() catch return false;

    return true;
}

export fn sdfgen_sddf_blk_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const blk: *sddf.Blk = @ptrCast(system);
    blk.serialiseConfig(std.mem.span(output_dir)) catch return false;

    return true;
}

export fn sdfgen_sddf_net(c_sdf: *align(8) anyopaque, c_device: *align(8) anyopaque, driver: *align(8) anyopaque, virt_tx: *align(8) anyopaque, virt_rx: *align(8) anyopaque, c_rx_dma_mr: ?*align(8) anyopaque) *anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const net = allocator.create(sddf.Net) catch @panic("OOM");
    const rx_dma_mr: ?*Mr = if (c_rx_dma_mr) |p| @ptrCast(p) else null;
    const options: sddf.Net.Options = .{
        .rx_dma_mr = rx_dma_mr,
    };
    net.* = sddf.Net.init(allocator, sdf, @ptrCast(c_device), @ptrCast(driver), @ptrCast(virt_tx), @ptrCast(virt_rx), options);

    return net;
}

export fn sdfgen_sddf_net_add_client_with_copier(system: *align(8) anyopaque, client: *align(8) anyopaque, copier: *align(8) anyopaque, mac_addr: [*c]u8, rx: bool, tx: bool) bindings.sdfgen_sddf_status_t {
    const net: *sddf.Net = @ptrCast(system);
    var options: sddf.Net.ClientOptions = .{};
    if (mac_addr) |a| {
        options.mac_addr = std.mem.span(a);
    }
    options.rx = rx;
    options.tx = tx;
    net.addClientWithCopier(@ptrCast(client), @ptrCast(copier), options) catch |e| {
        switch (e) {
            sddf.Net.Error.DuplicateClient => return 1,
            sddf.Net.Error.InvalidClient => return 2,
            sddf.Net.Error.DuplicateCopier => return 100,
            sddf.Net.Error.DuplicateMacAddr => return 101,
            sddf.Net.Error.InvalidMacAddr => return 102,
            sddf.Net.Error.InvalidOptions => return 103,
            // Should never happen when adding a client
            sddf.Net.Error.NotConnected => @panic("internal error"),
        }
    };

    return 0;
}

export fn sdfgen_sddf_net_connect(system: *align(8) anyopaque) bool {
    const net: *sddf.Net = @ptrCast(system);
    net.connect() catch return false;

    return true;
}

export fn sdfgen_sddf_net_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const net: *sddf.Net = @ptrCast(system);
    net.serialiseConfig(std.mem.span(output_dir)) catch return false;
    return true;
}

export fn sdfgen_sddf_net_destroy(system: *align(8) anyopaque) void {
    const net: *sddf.Net = @ptrCast(system);
    net.deinit();
    allocator.destroy(net);
}

export fn sdfgen_sddf_gpu(c_sdf: *align(8) anyopaque, c_device: *align(8) anyopaque, driver: *align(8) anyopaque, virt: *align(8) anyopaque) *anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const gpu = allocator.create(sddf.Gpu) catch @panic("OOM");
    gpu.* = sddf.Gpu.init(allocator, sdf, @ptrCast(c_device), @ptrCast(driver), @ptrCast(virt), .{});

    return gpu;
}

export fn sdfgen_sddf_gpu_destroy(system: *align(8) anyopaque) void {
    const gpu: *sddf.Gpu = @ptrCast(system);
    gpu.deinit();
    allocator.destroy(gpu);
}

export fn sdfgen_sddf_gpu_add_client(system: *align(8) anyopaque, client: *align(8) anyopaque) bindings.sdfgen_sddf_status_t {
    const gpu: *sddf.Gpu = @ptrCast(system);
    gpu.addClient(@ptrCast(client)) catch |e| {
        switch (e) {
            sddf.Gpu.Error.DuplicateClient => return 1,
            sddf.Gpu.Error.InvalidClient => return 2,
            // Should never happen when adding a client
            sddf.Gpu.Error.NotConnected => @panic("internal error"),
        }
    };

    return 0;
}

export fn sdfgen_sddf_gpu_connect(system: *align(8) anyopaque) bool {
    const gpu: *sddf.Gpu = @ptrCast(system);
    gpu.connect() catch return false;

    return true;
}

export fn sdfgen_sddf_gpu_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const gpu: *sddf.Gpu = @ptrCast(system);
    gpu.serialiseConfig(std.mem.span(output_dir)) catch return false;

    return true;
}

export fn sdfgen_vmm(c_sdf: *align(8) anyopaque, vmm_pd: *align(8) anyopaque, vm: *align(8) anyopaque, c_dtb: *align(8) anyopaque, dtb_size: u64, one_to_one_ram: bool) *anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const vmm = allocator.create(Vmm) catch @panic("OOM");
    vmm.* = Vmm.init(allocator, sdf, @ptrCast(vmm_pd), @ptrCast(vm), @ptrCast(c_dtb), dtb_size, .{
        .one_to_one_ram = one_to_one_ram,
    });

    return vmm;
}

export fn sdfgen_vmm_add_passthrough_device(c_vmm: *align(8) anyopaque, c_device: *align(8) anyopaque) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const device: *dtb.Node = @ptrCast(c_device);
    vmm.addPassthroughDevice(device, .{}) catch |e| {
        log.err("failed to add passthrough device '{s}' to VMM '{s}': {any}", .{ device.name, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_add_passthrough_device_regions(c_vmm: *align(8) anyopaque, c_device: *align(8) anyopaque, regions: [*c]u8, num_regions: u8) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const device: *dtb.Node = @ptrCast(c_device);
    vmm.addPassthroughDevice(device, .{
        .regions = if (regions == null) null else regions[0..num_regions],
        .irqs = &.{},
    }) catch |e| {
        log.err("failed to add passthrough regions for device '{s}' to VMM '{s}': {any}", .{ device.name, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_add_passthrough_device_irqs(c_vmm: *align(8) anyopaque, c_device: *align(8) anyopaque, irqs: [*c]u8, num_irqs: u8) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const device: *dtb.Node = @ptrCast(c_device);
    vmm.addPassthroughDevice(device, .{
        .regions = &.{},
        .irqs = if (irqs == null) null else irqs[0..num_irqs],
    }) catch |e| {
        log.err("failed to add passthrough IRQs for device '{s}' to VMM '{s}': {any}", .{ device.name, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_add_passthrough_irq(c_vmm: *align(8) anyopaque, c_irq: *align(8) anyopaque) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const irq: *Irq = @ptrCast(c_irq);
    vmm.addPassthroughIrq(irq.*) catch |e| {
        log.err("failed to add passthrough IRQ '{}' to VMM '{s}': {any}", .{ irq.irq, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_add_virtio_mmio_console(c_vmm: *align(8) anyopaque, c_device: *align(8) anyopaque, serial: *align(8) anyopaque) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const device: *dtb.Node = @ptrCast(c_device);
    vmm.addVirtioMmioConsole(device, @ptrCast(serial)) catch |e| {
        log.err("failed to add virtIO MMIO console device '{s}' to VMM '{s}': {any}", .{ device.name, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_add_virtio_mmio_blk(c_vmm: *align(8) anyopaque, c_device: *align(8) anyopaque, blk: *align(8) anyopaque, partition: u32) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const device: *dtb.Node = @ptrCast(c_device);
    vmm.addVirtioMmioBlk(device, @ptrCast(blk), .{
        .partition = partition,
    }) catch |e| {
        log.err("failed to add virtIO MMIO block device '{s}' to VMM '{s}': {any}", .{ device.name, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_add_virtio_mmio_net(c_vmm: *align(8) anyopaque, c_device: *align(8) anyopaque, net: *align(8) anyopaque, copier: *align(8) anyopaque, mac_addr: [*c]u8) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    const device: *dtb.Node = @ptrCast(c_device);
    var options: sddf.Net.ClientOptions = .{};
    if (mac_addr) |a| {
        options.mac_addr = std.mem.span(a);
    }
    vmm.addVirtioMmioNet(device, @ptrCast(net), @ptrCast(copier), options) catch |e| {
        log.err("failed to add virtIO MMIO net device '{s}' to VMM '{s}': {any}", .{ device.name, vmm.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_vmm_connect(c_vmm: *align(8) anyopaque) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    vmm.connect() catch return false;

    return true;
}

export fn sdfgen_vmm_serialise_config(c_vmm: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const vmm: *Vmm = @ptrCast(c_vmm);
    vmm.serialiseConfig(std.mem.span(output_dir)) catch return false;

    return true;
}

export fn sdfgen_lionsos_fs_fat(c_sdf: *align(8) anyopaque, c_fs: *align(8) anyopaque, c_client: *align(8) anyopaque, blk: *align(8) anyopaque, partition: u32) ?*anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const fs_pd: *Pd = @ptrCast(c_fs);
    const fs = allocator.create(lionsos.FileSystem.Fat) catch @panic("OOM");
    fs.* = lionsos.FileSystem.Fat.init(allocator, sdf, fs_pd, @ptrCast(c_client), @ptrCast(blk), .{
        .partition = partition,
    }) catch |e| {
        log.err("failed to create FAT file system '{s}': {any}", .{ fs_pd.name, e });
        return null;
    };

    return fs;
}

export fn sdfgen_lionsos_fs_fat_connect(system: *align(8) anyopaque) bool {
    const fat: *lionsos.FileSystem.Fat = @ptrCast(system);
    fat.connect() catch |e| {
        log.err("failed to connect FAT file system '{s}': {any}", .{ fat.fs.fs.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_lionsos_fs_fat_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const fat: *lionsos.FileSystem.Fat = @ptrCast(system);
    fat.serialiseConfig(std.mem.span(output_dir)) catch |e| {
        log.err("failed to serialise FAT file system '{s}': {any}", .{ fat.fs.fs.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_lionsos_fs_nfs(c_sdf: *align(8) anyopaque, c_fs: *align(8) anyopaque, c_client: *align(8) anyopaque, c_net: *align(8) anyopaque, c_net_copier: *align(8) anyopaque, mac_addr: [*c]u8, c_serial: *align(8) anyopaque, c_timer: *align(8) anyopaque, nfs_server: [*c]u8, nfs_export_path: [*c]u8) ?*anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const fs_pd: *Pd = @ptrCast(c_fs);
    const fs = allocator.create(lionsos.FileSystem.Nfs) catch @panic("OOM");
    var options: lionsos.FileSystem.Nfs.Options = .{
        .server = std.mem.span(nfs_server),
        .export_path = std.mem.span(nfs_export_path),
    };
    if (mac_addr) |a| {
        options.mac_addr = std.mem.span(a);
    }
    fs.* = lionsos.FileSystem.Nfs.init(allocator, sdf, fs_pd, @ptrCast(c_client), @ptrCast(c_net), @ptrCast(c_net_copier), @ptrCast(c_serial), @ptrCast(c_timer), options) catch |e| {
        log.err("failed to create NFS file system '{s}': {any}", .{ fs_pd.name, e });
        return null;
    };

    return fs;
}

export fn sdfgen_lionsos_fs_nfs_connect(system: *align(8) anyopaque) bool {
    const nfs: *lionsos.FileSystem.Nfs = @ptrCast(system);
    nfs.connect() catch |e| {
        log.err("failed to connect NFS file system '{s}': {any}", .{ nfs.fs.fs.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_lionsos_fs_nfs_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const nfs: *lionsos.FileSystem.Nfs = @ptrCast(system);
    nfs.serialiseConfig(std.mem.span(output_dir)) catch |e| {
        log.err("failed to serialise NFS file system '{s}': {any}", .{ nfs.fs.fs.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_lionsos_fs_nfs_destroy(system: *align(8) anyopaque) void {
    const nfs: *lionsos.FileSystem.Nfs = @ptrCast(system);
    nfs.deinit();
}

export fn sdfgen_lionsos_fs_vmfs(c_sdf: *align(8) anyopaque, c_fs_vm_sys: *align(8) anyopaque, c_client: *align(8) anyopaque, c_blk: *align(8) anyopaque, c_virtio_device: *align(8) anyopaque, partition: u32) ?*anyopaque {
    const sdf: *SystemDescription = @ptrCast(c_sdf);
    const fs = allocator.create(lionsos.FileSystem.VmFs) catch @panic("OOM");

    const vmm: *Vmm = @ptrCast(c_fs_vm_sys);

    fs.* = lionsos.FileSystem.VmFs.init(allocator, sdf, vmm, @ptrCast(c_client), @ptrCast(c_blk), @ptrCast(c_virtio_device), .{ .partition = partition }) catch |e| {
        log.err("failed to create VmFs file system '{s}': {any}", .{ vmm.vmm.name, e });
        return null;
    };

    return fs;
}

export fn sdfgen_lionsos_fs_vmfs_connect(system: *align(8) anyopaque) bool {
    const vmfs: *lionsos.FileSystem.VmFs = @ptrCast(system);
    vmfs.connect() catch |e| {
        log.err("failed to connect VmFs file system '{s}': {any}", .{ vmfs.fs_vm_sys.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_lionsos_fs_vmfs_serialise_config(system: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const vmfs: *lionsos.FileSystem.VmFs = @ptrCast(system);
    vmfs.serialiseConfig(std.mem.span(output_dir)) catch |e| {
        log.err("failed to serialise VmFs file system '{s}': {any}", .{ vmfs.fs_vm_sys.vmm.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_sddf_lwip(c_sdf: *align(8) anyopaque, c_net: *align(8) anyopaque, c_pd: *align(8) anyopaque) *anyopaque {
    const lib = allocator.create(sddf.Lwip) catch @panic("OOM");
    lib.* = sddf.Lwip.init(allocator, @ptrCast(c_sdf), @ptrCast(c_net), @ptrCast(c_pd));
    return lib;
}

export fn sdfgen_sddf_lwip_connect(c_lib: *align(8) anyopaque) bool {
    const lib: *sddf.Lwip = @ptrCast(c_lib);
    lib.connect() catch |e| {
        log.err("failed to connect lwIP '{s}': {any}", .{ lib.pd.name, e });
        return false;
    };

    return true;
}

export fn sdfgen_sddf_lwip_serialise_config(c_lib: *align(8) anyopaque, output_dir: [*c]u8) bool {
    const lib: *sddf.Lwip = @ptrCast(c_lib);
    lib.serialiseConfig(std.mem.span(output_dir)) catch return false;

    return true;
}
