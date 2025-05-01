const std = @import("std");
const mod_sdf = @import("sdf.zig");
const sddf = @import("sddf.zig");
const data = @import("data.zig");
const log = @import("log.zig");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const ConfigResources = data.Resources;

pub const Gdb = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    debugger: *Pd,
    debug_pds: std.ArrayList(*Pd),
    debugger_config: ConfigResources.Gdb,

    connected: bool,

    pub const Error = error{
        InvalidCopier,
        NoSubsystem,
        DuplicateDebugPd,
        AlreadyConnected,
        NotConnected,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, debugger: *Pd) Gdb {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .debugger = debugger,
            .debug_pds = std.ArrayList(*Pd).init(allocator),
            .debugger_config = std.mem.zeroInit(ConfigResources.Gdb, .{}),
            .connected = false,
        };
    }

    pub fn addPd(system: *Gdb, debug_pd: *Pd) !void {
        // Check that the pd is not already added
        for (system.debug_pds.items) |existing_debug_pd| {
            if (std.mem.eql(u8, existing_debug_pd.name, debug_pd.name)) {
                return Error.DuplicateDebugPd;
            }
        }

        system.debug_pds.append(debug_pd) catch @panic("Could not add debug pd to gdb system!");
    }

    pub fn connect(system: *Gdb) !void {
        if (system.connected) return Error.AlreadyConnected;

        for (system.debug_pds.items) |debug_pd| {
            // Add the debug PD as a child of the debugger.
            const id = system.debugger.addChild(debug_pd, .{}) catch |e| {
                log.err("failed to add child '{s}' to parent '{s}': {any}", .{ system.debugger.name, debug_pd.name, e });
                return;
            };
            std.log.err("Adding {s} at id: {any}", .{ debug_pd.name, id });
        }
        system.debugger_config.num_debugees = system.debug_pds.items.len;
        system.connected = true;
        std.log.err("Finished connect", .{});
    }

    pub fn serialiseConfig(system: *Gdb, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;
        try data.serialize(allocator, system.debugger_config, prefix, "debugger_config");
    }
};
