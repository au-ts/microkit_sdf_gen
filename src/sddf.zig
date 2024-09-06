const std = @import("std");
const builtin = @import("builtin");
const mod_sdf = @import("sdf.zig");
const dtb = @import("dtb");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Pd = SystemDescription.ProtectionDomain;
const ProgramImage = Pd.ProgramImage;
const Interrupt = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;
const SetVar = SystemDescription.SetVar;

///
/// Expected sDDF repository layout:
///     -- network/
///     -- serial/
///     -- drivers/
///         -- network/
///         -- serial/
///
/// Essentially there should be a top-level directory for a
/// device class and aa directory for each device class inside
/// 'drivers/'.
///
var drivers: std.ArrayList(Config.Driver) = undefined;
var classes: std.ArrayList(Config.DeviceClass) = undefined;

const CONFIG_FILENAME = "config.json";

/// Assumes probe() has been called
pub fn findDriver(compatibles: []const []const u8) ?Config.Driver {
    for (drivers.items) |driver| {
        // This is yet another point of weirdness with device trees. It is often
        // the case that there are multiple compatible strings for a device and
        // accompying driver. So we get the user to provide a list of compatible
        // strings, and we check for a match with any of the compatible strings
        // of a driver.
        for (compatibles) |compatible| {
            for (driver.compatible) |driver_compatible| {
                if (std.mem.eql(u8, driver_compatible, compatible)) {
                    // We have found a compatible driver
                    return driver;
                }
            }
        }
    }

    return null;
}

/// Assumes probe() has been called
pub fn compatibleDrivers(allocator: Allocator) ![]const []const u8 {
    // We already know how many drivers exist as well as all their compatible
    // strings, so we know exactly how large the array needs to be.
    var num_compatible: usize = 0;
    for (drivers.items) |driver| {
        num_compatible += driver.compatible.len;
    }
    var array = try std.ArrayList([]const u8).initCapacity(allocator, num_compatible);
    for (drivers.items) |driver| {
        for (driver.compatible) |compatible| {
            array.appendAssumeCapacity(compatible);
        }
    }

    return try array.toOwnedSlice();
}

pub fn wasmProbe(allocator: Allocator, driverConfigs: anytype, classConfigs: anytype) !void {
    drivers = std.ArrayList(Config.Driver).init(allocator);
    // TODO: we could init capacity with number of DeviceClassType fields
    classes = std.ArrayList(Config.DeviceClass).init(allocator);

    var i: usize = 0;
    while (i < driverConfigs.items.len) : (i += 1) {
        const config = driverConfigs.items[i].object;
        const json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, config.get("content").?.string, .{});
        try drivers.append(Config.Driver.fromJson(json, config.get("class").?.string));
    }
    // for (driverConfigs) |config| {
    //     const json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, config.get("content").?.content, .{});
    //     try drivers.append(Config.Driver.fromJson(json, config.get("class").?.name));
    // }

    i = 0;
    while (i < classConfigs.items.len) : (i += 1) {
        const config = classConfigs.items[i].object;
        const json = try std.json.parseFromSliceLeaky(Config.DeviceClass.Json, allocator, config.get("content").?.string, .{});
        try classes.append(Config.DeviceClass.fromJson(json, config.get("class").?.string));
    }
    // for (classConfigs) |config| {
    //     const json = try std.json.parseFromSliceLeaky(Config.DeviceClass.Json, allocator, config.get("content").?.content, .{});
    //     try classes.append(Config.DeviceClass.fromJson(json, config.get("class").?.name));
    // }
}

/// As part of the initilisation, we want to find all the JSON configuration
/// files, parse them, and built up a data structure for us to then search
/// through whenever we want to create a driver to the system description.
pub fn probe(allocator: Allocator, path: []const u8) !void {
    drivers = std.ArrayList(Config.Driver).init(allocator);
    // TODO: we could init capacity with number of DeviceClassType fields
    classes = std.ArrayList(Config.DeviceClass).init(allocator);

    std.log.info("starting sDDF probe", .{});
    std.log.info("opening sDDF root dir '{s}'", .{path});
    var sddf = try std.fs.cwd().openDir(path, .{});
    defer sddf.close();

    const device_classes = comptime std.meta.fields(Config.DeviceClass.Class);
    inline for (device_classes) |device_class| {
        // Search for all the drivers. For each device class we need
        // to iterate through each directory and find the config file
        // TODO: handle this gracefully
        var device_class_dir = try sddf.openDir("drivers/" ++ device_class.name, .{ .iterate = true });
        defer device_class_dir.close();
        var iter = device_class_dir.iterate();
        std.log.info("searching through: 'drivers/{s}'", .{device_class.name});
        while (try iter.next()) |entry| {
            // Under this directory, we should find the configuration file
            const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{entry.name}) catch @panic("OOM");
            defer allocator.free(config_path);
            // Attempt to open the configuration file. It is realistic to not
            // have every driver to have a configuration file associated with
            // it, especially during the development of sDDF.
            const config_file = device_class_dir.openFile(config_path, .{}) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        std.log.info("could not find config file at '{s}', skipping...", .{config_path});
                        continue;
                    },
                    else => return e,
                }
            };
            defer config_file.close();
            std.log.info("reading 'drivers/{s}/{s}/{s}'", .{ device_class.name ,entry.name, CONFIG_FILENAME });
            const config_size = (try config_file.stat()).size;
            const config = try config_file.reader().readAllAlloc(allocator, config_size);
            // TODO; free config? we'd have to dupe the json data when populating our data structures
            std.debug.assert(config.len == config_size);
            // TODO: we have no information if the parsing fails. We need to do some error output if
            // it the input is malformed.
            // TODO: should probably free the memory at some point
            // We are using an ArenaAllocator so calling parseFromSliceLeaky instead of parseFromSlice
            // is recommended.
            const json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, config, .{});

            try drivers.append(Config.Driver.fromJson(json, device_class.name));
        }
        // Look for all the configuration files inside each of the device class
        // sub-directories.
        const class_config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{device_class.name}) catch @panic("OOM");
        defer allocator.free(class_config_path);
        if (sddf.openFile(class_config_path, .{})) |class_config_file| {
            defer class_config_file.close();

            const config_size = (try class_config_file.stat()).size;
            const config = try class_config_file.reader().readAllAlloc(allocator, config_size);

            const json = try std.json.parseFromSliceLeaky(Config.DeviceClass.Json, allocator, config, .{});
            try classes.append(Config.DeviceClass.fromJson(json, device_class.name));
        } else |err| {
            switch (err) {
                error.FileNotFound => {
                    std.log.info("could not find class config file at '{s}', skipping...", .{class_config_path});
                },
                else => {
                    std.log.info("error accessing config file ({}) at '{s}', skipping...", .{ err, class_config_path });
                },
            }
        }
    }
}

pub const Config = struct {
    const Region = struct {
        /// Name of the region
        name: []const u8,
        /// Permissions to the region of memory once mapped in
        perms: []const u8,
        // TODO: do we need cached or can we decide based on the type?
        cached: bool,
        setvar_vaddr: ?[]const u8,
        page_size: usize,
        size: usize,
    };

    /// The actual IRQ number that gets registered with seL4
    /// is something we can determine from the device tree.
    const Irq = struct {
        channel_id: usize,
        /// Index into the 'interrupts' property of the Device Tree
        dt_index: usize,
    };

    /// In the case of drivers there is some extra information we want
    /// to store that is not specified in the JSON configuration.
    /// For example, the device class that the driver belongs to.
    pub const Driver = struct {
        name: []const u8,
        class: DeviceClass.Class,
        compatible: []const []const u8,
        resources: Resources,

        const Resources = struct {
            device_regions: []const Region,
            shared_regions: []const Region,
            irqs: []const Irq,
        };

        pub const Json = struct {
            name: []const u8,
            compatible: []const []const u8,
            resources: Resources,
        };

        pub fn fromJson(json: Json, class: []const u8) Driver {
            return .{
                .name = json.name,
                .class = DeviceClass.Class.fromStr(class),
                .compatible = json.compatible,
                .resources = json.resources,
            };
        }
    };

    pub const Component = struct {
        name: []const u8,
        type: []const u8,
        // resources: Resources,
    };

    pub const DeviceClass = struct {
        class: Class,
        resources: Resources,

        const Json = struct {
            resources: Resources,
        };

        pub fn fromJson(json: Json, class: []const u8) DeviceClass {
            return .{
                .class = DeviceClass.Class.fromStr(class),
                .resources = json.resources,
            };
        }

        /// These are the sDDF device classes that we expect to exist in the
        /// repository and will be searched through.
        /// You could instead have something in the repisitory to list the
        /// device classes or organise the repository differently, but I do
        /// not see the need for that kind of complexity at this time.
        const Class = enum {
            network,
            serial,
            timer,

            pub fn fromStr(str: []const u8) Class {
                inline for (std.meta.fields(Class)) |field| {
                    if (std.mem.eql(u8, str, field.name)) {
                        return @enumFromInt(field.value);
                    }
                }

                // TODO: don't panic
                @panic("Unexpected device class string given");
            }
        };

        const Resources = struct {
            regions: []const Region,
        };
    };
};

pub const DeviceTree = struct {
    /// Functionality relating the the ARM Generic Interrupt Controller.
    const ArmGicIrqType = enum {
        spi,
        ppi,
        extended_spi,
        extended_ppi,
    };

    pub fn armGicIrqType(irq_type: usize) !ArmGicIrqType {
        return switch (irq_type) {
            0x0 => .spi,
            0x1 => .ppi,
            0x2 => .extended_spi,
            0x3 => .extended_ppi,
            else => return error.InvalidArmIrqTypeValue,
        };
    }

    pub fn armGicIrqNumber(number: usize, irq_type: ArmGicIrqType) usize {
        return switch (irq_type) {
            .spi => number + 32,
            .ppi => number + 16,
            .extended_spi, .extended_ppi => @panic("Unexpected IRQ type"),
        };
    }

    pub fn armGicSpiTrigger(trigger: usize) !Interrupt.Trigger {
        return switch (trigger) {
            0x1 => return .edge,
            0x4 => return .level,
            else => return error.InvalidTriggerValue,
        };
    }
};

pub const TimerSystem = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    /// Protection Domain that will act as the driver for the timer
    driver: *Pd,
    /// Device Tree node for the timer device
    device: *dtb.Node,
    /// Client PDs serviced by the timer driver
    clients: std.ArrayList(*Pd),

    pub fn init(allocator: Allocator, sdf: *SystemDescription, driver: *Pd, device: *dtb.Node) TimerSystem {
        // First we have to set some properties on the driver. It is currently our policy that every timer
        // driver should be passive.
        driver.passive = true;
        // Clients also communicate to the driver via PPC
        driver.pp = true;

        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver = driver,
            .device = device,
            .clients = std.ArrayList(*Pd).init(allocator),
        };
    }

    pub fn deinit(system: *TimerSystem) void {
        system.clients.deinit();
    }

    pub fn addClient(system: *TimerSystem, client: *Pd) void {
        system.clients.append(client) catch @panic("Could not add client to TimerSystem");
    }

    pub fn connect(system: *TimerSystem) !void {
        // The driver must be passive and it must be able to receive protected procedure calls
        std.debug.assert(system.driver.passive);
        std.debug.assert(system.driver.pp);

        try createDriver(system.sdf, system.driver, system.device);
        for (system.clients.items) |client| {
            // In order to connect a client we simply have to create a channel between
            // each client and the driver.
            system.sdf.addChannel(Channel.create(system.driver, client));
        }
    }
};

/// TODO: these functions do very little error checking
pub const SerialSystem = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    driver_data_size: usize,
    client_data_size: usize,
    queue_size: usize,
    page_size: Mr.PageSize,
    driver: *Pd,
    device: *dtb.Node,
    virt_rx: ?*Pd,
    virt_tx: *Pd,
    clients: std.ArrayList(*Pd),
    rx: bool,

    pub const Options = struct {
        driver_data_size: usize = 0x4000,
        client_data_size: usize = 0x2000,
        queue_size: usize = 0x1000,
        rx: bool = true,
    };

    const Region = enum {
        data,
        queue,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd, virt_tx: *Pd, virt_rx: ?*Pd, options: Options) SerialSystem {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .driver_data_size = options.driver_data_size,
            .client_data_size = options.client_data_size,
            .queue_size = options.queue_size,
            .rx = options.rx,
            // TODO: sort out
            .page_size = .small,
            .clients = std.ArrayList(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .virt_rx = virt_rx,
            .virt_tx = virt_tx,
        };
    }

    pub fn addClient(system: *SerialSystem, client: *Pd) void {
        system.clients.append(client) catch @panic("Could not add client to SerialSystem");
    }

    fn rxConnectDriver(system: *SerialSystem) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "serial_driver_rx_{s}", .{ region.name }) catch @panic("OOM");
            const mr_size = blk: {
                if (@as(Region, @enumFromInt(region.value)) == .data) {
                    break :blk system.driver_data_size;
                } else {
                    break :blk system.queue_size;
                }
            };
            const mr = Mr.create(system.sdf, mr_name, mr_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // @ivanv: vaddr has invariant that needs to be checked
            const virt_vaddr = system.virt_rx.?.getMapableVaddr(&mr);
            const virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}_drv", .{ region.name }) catch @panic("OOM");
            const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
            system.virt_rx.?.addMap(virt_map);

            const driver_vaddr = system.driver.getMapableVaddr(&mr);
            const driver_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}", .{ region.name }) catch @panic("OOM");
            const driver_map = Map.create(mr, driver_vaddr, perms, true, driver_setvar_vaddr);
            system.driver.addMap(driver_map);
        }
    }

    fn txConnectDriver(system: *SerialSystem) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "serial_driver_tx_{s}", .{ region.name }) catch @panic("OOM");
            const mr_size = blk: {
                if (@as(Region, @enumFromInt(region.value)) == .data) {
                    break :blk system.driver_data_size;
                } else {
                    break :blk system.queue_size;
                }
            };
            const mr = Mr.create(system.sdf, mr_name, mr_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // @ivanv: vaddr has invariant that needs to be checked
            const virt_vaddr = system.virt_tx.getMapableVaddr(&mr);
            const virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}_drv", .{ region.name }) catch @panic("OOM");
            const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
            system.virt_tx.addMap(virt_map);

            const driver_vaddr = system.driver.getMapableVaddr(&mr);
            const driver_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}", .{ region.name }) catch @panic("OOM");
            const driver_map = Map.create(mr, driver_vaddr, perms, true, driver_setvar_vaddr);
            system.driver.addMap(driver_map);
        }
    }

    fn rxConnectClient(system: *SerialSystem, client: *Pd, client_zero: bool) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "serial_virt_rx_{s}_{s}", .{ client.name, region.name }) catch @panic("OOM");
            const mr_size = blk: {
                if (@as(Region, @enumFromInt(region.value)) == .data) {
                    break :blk system.driver_data_size;
                } else {
                    break :blk system.queue_size;
                }
            };
            const mr = Mr.create(system.sdf, mr_name, mr_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // @ivanv: vaddr has invariant that needs to be checked
            const virt_vaddr = system.virt_rx.?.getMapableVaddr(&mr);
            var virt_setvar_vaddr: ?[]const u8 = null;
            if (client_zero) {
                virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}_cli0", .{ region.name }) catch @panic("OOM");
            }
            const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
            system.virt_rx.?.addMap(virt_map);

            const client_vaddr = client.getMapableVaddr(&mr);
            const client_setvar_vaddr = std.fmt.allocPrint(system.allocator, "serial_rx_{s}", .{ region.name }) catch @panic("OOM");
            const client_map = Map.create(mr, client_vaddr, perms, true, client_setvar_vaddr);
            client.addMap(client_map);
        }
    }

    fn txConnectClient(system: *SerialSystem, client: *Pd, client_zero: bool) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "serial_virt_tx_{s}_{s}", .{ client.name, region.name }) catch @panic("OOM");
            const mr_size = blk: {
                if (@as(Region, @enumFromInt(region.value)) == .data) {
                    break :blk system.driver_data_size;
                } else {
                    break :blk system.queue_size;
                }
            };
            const mr = Mr.create(system.sdf, mr_name, mr_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // @ivanv: vaddr has invariant that needs to be checked
            const virt_vaddr = system.virt_tx.getMapableVaddr(&mr);
            var virt_setvar_vaddr: ?[]const u8 = null;
            if (client_zero) {
                virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}_cli0", .{ region.name }) catch @panic("OOM");
            }
            const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
            system.virt_tx.addMap(virt_map);

            const client_vaddr = client.getMapableVaddr(&mr);
            const client_setvar_vaddr = std.fmt.allocPrint(system.allocator, "serial_tx_{s}", .{ region.name }) catch @panic("OOM");
            const client_map = Map.create(mr, client_vaddr, perms, true, client_setvar_vaddr);
            client.addMap(client_map);
        }
    }

    pub fn connect(system: *SerialSystem) !void {
        var sdf = system.sdf;

        // 1. Create all the channels
        // 1.1 Create channels between driver and multiplexors
        try createDriver(sdf, system.driver, system.device);
        const ch_driver_virt_tx = Channel.create(system.driver, system.virt_tx);
        sdf.addChannel(ch_driver_virt_tx);
        if (system.rx) {
            const ch_driver_virt_rx = Channel.create(system.driver, system.virt_rx.?);
            sdf.addChannel(ch_driver_virt_rx);
        }
        // 1.2 Create channels between multiplexors and clients
        for (system.clients.items) |client| {
            const ch_virt_tx_client = Channel.create(system.virt_tx, client);
            sdf.addChannel(ch_virt_tx_client);

            if (system.rx) {
                const ch_virt_rx_client = Channel.create(system.virt_rx.?, client);
                sdf.addChannel(ch_virt_rx_client);
            }
        }
        if (system.rx) {
            system.rxConnectDriver();
        }
        system.txConnectDriver();
        for (system.clients.items, 0..) |client, i| {
            if (system.rx) {
                system.rxConnectClient(client, i == 0);
            }
            system.txConnectClient(client, i == 0);
        }
    }
};

pub const NetworkSystem = struct {
    pub const Options = struct {
        region_size: usize = 0x200_000,
    };

    allocator: Allocator,
    sdf: *SystemDescription,
    region_size: usize,
    page_size: Mr.PageSize,
    driver: *Pd,
    device: *dtb.Node,
    virt_rx: *Pd,
    virt_tx: *Pd,
    copiers: std.ArrayList(*Pd),
    clients: std.ArrayList(*Pd),

    const Region = enum {
        data,
        active,
        free,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, device: *dtb.Node, driver: *Pd, virt_rx: *Pd, virt_tx: *Pd, options: Options) NetworkSystem {
        const page_size = SystemDescription.MemoryRegion.PageSize.optimal(sdf, options.region_size);
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .region_size = options.region_size,
            .page_size = page_size,
            .clients = std.ArrayList(*Pd).init(allocator),
            .copiers = std.ArrayList(*Pd).init(allocator),
            .driver = driver,
            .device = device,
            .virt_rx = virt_rx,
            .virt_tx = virt_tx,
        };
    }

    // TODO: support the case where clients do not have a copier
    // Note that we should check whether it's possible that some clients in a system have copiers
    // while others do not even though they're in the same system.
    pub fn addClient(system: *NetworkSystem, client: *Pd) void {
        system.clients.append(client) catch @panic("Could not add client to NetworkSystem");
    }

    pub fn addClientWithCopier(system: *NetworkSystem, client: *Pd, copier: *Pd) void {
        system.addClient(client);
        system.copiers.append(copier) catch @panic("Could not add copier to NetworkSystem");
    }

    fn rxConnectDriver(system: *NetworkSystem) Mr {
        var data_mr: Mr = undefined;
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "net_driver_rx_{s}", .{ region.name }) catch @panic("OOM");
            const mr = Mr.create(system.sdf, mr_name, system.region_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms = switch (@as(Region, @enumFromInt(region.value))) {
                .data => .{ .read = true },
                else => .{ .read = true, .write = true },
            };
            // Data regions are not to be mapped in the driver's address space
            // @ivanv: gross syntax
            if (@as(Region, @enumFromInt(region.value)) != .data) {
                const driver_vaddr = system.driver.getMapableVaddr(&mr);
                const driver_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}", .{ region.name }) catch @panic("OOM");
                const driver_map = Map.create(mr, driver_vaddr, perms, true, driver_setvar_vaddr);
                system.driver.addMap(driver_map);
            } else {
                system.virt_rx.addSetVar(SetVar.create("buffer_data_paddr", &mr));
            }

            // @ivanv: vaddr has invariant that needs to be checked
            // @ivanv: gross syntax
            if (@as(Region, @enumFromInt(region.value)) != .data) {
                const virt_vaddr = system.virt_rx.getMapableVaddr(&mr);
                const virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}_drv", .{ region.name }) catch @panic("OOM");
                const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
                system.virt_rx.addMap(virt_map);
            } else {
                const virt_vaddr = system.virt_rx.getMapableVaddr(&mr);
                const virt_map = Map.create(mr, virt_vaddr, perms, true, "buffer_data_vaddr");
                system.virt_rx.addMap(virt_map);
                data_mr = mr;
            }
        }

        return data_mr;
    }

    fn txConnectDriver(system: *NetworkSystem) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "net_driver_tx_{s}", .{ region.name }) catch @panic("OOM");
            const mr = Mr.create(system.sdf, mr_name, system.region_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // Data regions are not to be mapped in the driver's address space
            // @ivanv: gross syntax
            if (@as(Region, @enumFromInt(region.value)) != .data) {
                const driver_vaddr = system.driver.getMapableVaddr(&mr);
                const driver_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}", .{ region.name }) catch @panic("OOM");
                const driver_map = Map.create(mr, driver_vaddr, perms, true, driver_setvar_vaddr);
                system.driver.addMap(driver_map);

                // @ivanv: vaddr has invariant that needs to be checked
                const virt_vaddr = system.virt_tx.getMapableVaddr(&mr);
                const virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}_drv", .{ region.name }) catch @panic("OOM");
                const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
                system.virt_tx.addMap(virt_map);
            }
        }
    }

    fn clientRxConnect(system: *NetworkSystem, client: *Pd, rx: *Pd) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "net_client_rx_{s}_{s}", .{ client.name, region.name }) catch @panic("OOM");
            const mr = Mr.create(system.sdf, mr_name, system.region_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // @ivanv: vaddr has invariant that needs to be checked
            const virt_vaddr = rx.getMapableVaddr(&mr);
            var virt_setvar_vaddr: ?[]const u8 = null;
            // @ivanv: gross syntax
            if (@as(Region, @enumFromInt(region.value)) != .data) {
                virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}_cli", .{ region.name }) catch @panic("OOM");
            } else {
                virt_setvar_vaddr = "cli_buffer_data_region";
            }
            const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
            rx.addMap(virt_map);

            const client_vaddr = client.getMapableVaddr(&mr);
            var client_setvar_vaddr: ?[]const u8 = null;
            if (@as(Region, @enumFromInt(region.value)) == .data) {
                client_setvar_vaddr = "rx_buffer_data_region";
            } else {
                client_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}", .{ region.name }) catch @panic("OOM");
            }
            const client_map = Map.create(mr, client_vaddr, perms, true, client_setvar_vaddr);
            client.addMap(client_map);
        }
    }

    fn clientTxConnect(system: *NetworkSystem, client: *Pd, tx: *Pd, client_idx: usize) void {
        inline for (std.meta.fields(Region)) |region| {
            const mr_name = std.fmt.allocPrint(system.allocator, "net_client_tx_{s}_{s}", .{ client.name, region.name }) catch @panic("OOM");
            const mr = Mr.create(system.sdf, mr_name, system.region_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);
            const perms: Map.Permissions = .{ .read = true, .write = true };
            // @ivanv: vaddr has invariant that needs to be checked
            const virt_vaddr = tx.getMapableVaddr(&mr);
            var virt_setvar_vaddr: ?[]const u8 = null;
            // @ivanv: gross syntax
            if (client_idx == 0 and @as(Region, @enumFromInt(region.value)) != .data) {
                virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}_cli0", .{ region.name }) catch @panic("OOM");
            } else if (@as(Region, @enumFromInt(region.value)) == .data) {
                virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "buffer_data_region_cli{}_vaddr", .{ client_idx }) catch @panic("OOM");
            }
            const virt_map = Map.create(mr, virt_vaddr, perms, true, virt_setvar_vaddr);
            tx.addMap(virt_map);

            const client_vaddr = client.getMapableVaddr(&mr);
            var client_setvar_vaddr: ?[]const u8 = null;
            if (@as(Region, @enumFromInt(region.value)) == .data) {
                client_setvar_vaddr = "tx_buffer_data_region";
            } else {
                client_setvar_vaddr = std.fmt.allocPrint(system.allocator, "tx_{s}", .{ region.name }) catch @panic("OOM");
            }
            const client_map = Map.create(mr, client_vaddr, perms, true, client_setvar_vaddr);
            client.addMap(client_map);

            if (@as(Region, @enumFromInt(region.value)) == .data) {
                const data_setvar = std.fmt.allocPrint(system.allocator, "buffer_data_region_cli{}_paddr", .{ client_idx }) catch @panic("OOM");
                system.virt_tx.addSetVar(SetVar.create(data_setvar, &mr));
            }
        }
    }

    // We need to map in the data region between the driver/virt into the copier with setvar "virt_buffer_data_region".
    fn copierRxConnect(system: *NetworkSystem, copier: *Pd, first_client: bool, virt_data_mr: Mr) void {
        inline for (std.meta.fields(Region)) |region| {

            const mr_name = std.fmt.allocPrint(system.allocator, "net_{s}_{s}", .{ copier.name, region.name }) catch @panic("OOM");
            const mr = Mr.create(system.sdf, mr_name, system.region_size, null, system.page_size);
            system.sdf.addMemoryRegion(mr);

            // Map the MR into the virtualiser RX and copier RX
            const virt_vaddr = system.virt_rx.getMapableVaddr(&mr);
            if (@as(Region, @enumFromInt(region.value)) != .data) {
                var virt_setvar_vaddr: ?[]const u8 = null;
                if (first_client) {
                    virt_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}_cli0", .{ region.name }) catch @panic("OOM");
                }
                const virt_map = Map.create(mr, virt_vaddr, .{ .read = true, .write = true }, true, virt_setvar_vaddr);
                system.virt_rx.addMap(virt_map);
            }

            if (@as(Region, @enumFromInt(region.value)) == .data) {
                const copier_vaddr = copier.getMapableVaddr(&virt_data_mr);
                const copier_map = Map.create(virt_data_mr, copier_vaddr, .{ .read = true, .write = true }, true, "virt_buffer_data_region");
                copier.addMap(copier_map);
            } else {
                const copier_vaddr = copier.getMapableVaddr(&mr);
                const copier_setvar_vaddr = std.fmt.allocPrint(system.allocator, "rx_{s}_virt", .{ region.name }) catch @panic("OOM");
                const copier_map = Map.create(mr, copier_vaddr, .{ .read = true, .write = true }, true, copier_setvar_vaddr);
                copier.addMap(copier_map);
            }
        }
    }

    pub fn connect(system: *NetworkSystem) !void {
        var sdf = system.sdf;
        try createDriver(sdf, system.driver, system.device);

        // TODO: The driver needs the HW ring buffer memory region as well. In the future
        // we should make this configurable but right no we'll just add it here
        const hw_ring_buffer_mr = Mr.create(system.sdf, "hw_ring_buffer", 0x10_000, null, .small);
        system.sdf.addMemoryRegion(hw_ring_buffer_mr);
        system.driver.addMap(Map.create(
            hw_ring_buffer_mr,
            system.driver.getMapableVaddr(&hw_ring_buffer_mr),
            .{ .read = true, .write = true },
            false,
            "hw_ring_buffer_vaddr"
        ));

        system.driver.addSetVar(SetVar.create("hw_ring_buffer_paddr", @constCast(&hw_ring_buffer_mr)));

        sdf.addChannel(Channel.create(system.driver, system.virt_tx));
        sdf.addChannel(Channel.create(system.driver, system.virt_rx));

        const virt_data_mr = system.rxConnectDriver();
        system.txConnectDriver();

        for (system.clients.items, 0..) |client, i| {
            // TODO: we have an assumption that all copiers are RX copiers
            sdf.addChannel(Channel.create(system.copiers.items[i], client));
            sdf.addChannel(Channel.create(system.virt_tx, client));
            sdf.addChannel(Channel.create(system.copiers.items[i], system.virt_rx));

            system.copierRxConnect(system.copiers.items[i], i == 0, virt_data_mr);
            // TODO: we assume there exists a copier for each client, on the RX side
            system.clientRxConnect(client, system.copiers.items[i]);
            system.clientTxConnect(client, system.virt_tx, i);
        }
    }
};

/// Given the DTB node for the device and the SDF program image, we can figure
/// all the resources that need to be added to the system description.
pub fn createDriver(sdf: *SystemDescription, pd: *Pd, device: *dtb.Node) !void {
    // First thing to do is find the driver configuration for the device given.
    // The way we do that is by searching for the compatible string described in the DTB node.
    const compatible = device.prop(.Compatible).?;

    // TODO: It is expected for a lot of devices to have multiple compatible strings,
    // we need to deal with that here.
    if (!builtin.target.cpu.arch.isWasm()) {
        std.log.debug("Creating driver for device: '{s}'", .{device.name});
        std.log.debug("Compatible with:", .{});
        for (compatible) |c| {
            std.log.debug("     '{s}'", .{c});
        }
    }
    // Get the driver based on the compatible string are given, assuming we can
    // find it.
    const driver = if (findDriver(compatible)) |d| d else return error.UnknownDevice;
    // TODO: is there a better way to do this
    if(!builtin.target.cpu.arch.isWasm()) {
        std.log.debug("Found compatible driver '{s}'", .{driver.name});
    }
    // TODO: fix, this should be from the DTS

    const interrupts = device.prop(.Interrupts).?;

    if (device.prop(.Reg)) |device_reg| {
        // TODO: casting from u128 to u64
        // Some device registers may not be page aligned so we do that here.
        var device_paddr: u64 = @intCast((device_reg[0][0] >> 12) << 12);
        // Why is this logic needed? Well it turns out device trees are great and the
        // region of memory that a device occupies in physical memory is... not in the
        // 'reg' property of the device's node in the tree. So here what we do is, as
        // long as there is a parent node, we look and see if it has a memory address
        // and add it to the device's declared 'address'. This needs to be done because
        // some device trees have nodes which are offsets of the parent nodes, this is
        // common with buses. For example, with the Odroid-C4 the main UART is 0x3000
        // offset of the parent bus. We are only interested in the full physical address,
        // hence this logic.
        var parent_node_maybe: ?*dtb.Node = device.parent;
        while (parent_node_maybe) |parent_node| : (parent_node_maybe = parent_node.parent) {
            const parent_node_reg = parent_node.prop(.Reg);
            if (parent_node_reg) |reg| {
                device_paddr += @intCast(reg[0][0]);
            }
        }
    }

    // For each set of interrupt values in the device tree 'interrupts' property
    // we expect three entries.
    //      1st is the IRQ type.
    //      2nd is the IRQ number.
    //      3rd is the IRQ trigger.
    // Note that this is specific to the ARM architecture. Fucking DTS people couldn't
    // make it easy to distinguish based on architecture. :((
    for (interrupts) |interrupt| {
        std.debug.assert(interrupt.len == 3);
    }

    // IRQ device tree handling is currently ARM specific.
    std.debug.assert(sdf.arch == .aarch64 or sdf.arch == .aarch32);

    // TODO: support more than one device region, it will most likely be needed in the future.
    std.debug.assert(driver.resources.device_regions.len <= 1);
    if (driver.resources.device_regions.len > 0) {
        for (driver.resources.device_regions) |region| {
            const device_paddr: u64 = @intCast((device.prop(.Reg).?[0][0] >> 12) << 12);

            const page_size = try Mr.PageSize.fromInt(region.page_size, sdf.arch);
            const mr_name = std.fmt.allocPrint(sdf.allocator, "{s}_{s}", .{ driver.name, region.name }) catch @panic("OOM");
            const mr = Mr.create(sdf, mr_name, region.size, device_paddr, page_size);
            sdf.addMemoryRegion(mr);

            const perms = Map.Permissions.fromString(region.perms);
            const vaddr = pd.getMapableVaddr(&mr);
            const map = Map.create(mr, vaddr, perms, region.cached, region.setvar_vaddr);
            pd.addMap(map);
        }
    }

    // For all driver IRQs, find the corresponding entry in the device tree and
    // process it for the SDF.
    for (driver.resources.irqs) |driver_irq| {
        const dt_irq = interrupts[driver_irq.dt_index];

        // Determine the IRQ trigger and (software-observable) number based on the device tree.
        const irq_type = try DeviceTree.armGicIrqType(dt_irq[0]);
        const irq_number = DeviceTree.armGicIrqNumber(dt_irq[1], irq_type);
        // Assume trigger is level if we are dealing with an IRQ that is not an SPI.
        // TODO: come back to this, do we need to care about the trigger for non-SPIs?
        const irq_trigger = if (irq_type == .spi) try DeviceTree.armGicSpiTrigger(dt_irq[2]) else .level;

        const irq = SystemDescription.Interrupt.create(irq_number, irq_trigger, driver_irq.channel_id);
        try pd.addInterrupt(irq);
    }
}
