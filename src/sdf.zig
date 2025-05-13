const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const log = @import("log.zig");

pub const SystemDescription = struct {
    allocator: Allocator,
    xml_data: ArrayList(u8),
    xml: ArrayList(u8).Writer,
    arch: Arch,
    pds: ArrayList(*ProtectionDomain),
    mrs: ArrayList(MemoryRegion),
    channels: ArrayList(Channel),
    /// Highest allocatable physical address on the platform
    paddr_top: u64,

    /// Supported architectures by seL4
    /// Expilictly assign values for better interop with C bindings.
    pub const Arch = enum(u8) {
        aarch32 = 0,
        aarch64 = 1,
        riscv32 = 2,
        riscv64 = 3,
        x86 = 4,
        x86_64 = 5,

        pub fn isArm(arch: Arch) bool {
            return arch == .aarch32 or arch == .aarch64;
        }

        pub fn isRiscv(arch: Arch) bool {
            return arch == .riscv32 or arch == .riscv64;
        }

        pub fn isX86(arch: Arch) bool {
            return arch == .x86 or arch == .x86_64;
        }

        pub fn defaultPageSize(_: Arch) u64 {
            // All the architectures we currently support default to this page size.
            return 0x1000;
        }

        pub fn pageAligned(arch: Arch, n: u64) bool {
            return (n % arch.defaultPageSize() == 0);
        }

        pub fn roundDownToPage(arch: Arch, n: u64) u64 {
            const page_size = arch.defaultPageSize();
            if (n < page_size) {
                return 0;
            } else if (n % page_size == 0) {
                return n;
            } else {
                return n - (n % page_size);
            }
        }

        pub fn roundUpToPage(arch: Arch, n: u64) u64 {
            const page_size = arch.defaultPageSize();
            if (n < page_size) {
                return page_size;
            } else if (n % page_size == 0) {
                return n;
            } else {
                return n + (page_size - (n % page_size));
            }
        }
    };

    pub const SetVar = struct {
        symbol: []const u8,
        name: []const u8,

        pub fn create(symbol: []const u8, mr: *const MemoryRegion) SetVar {
            return SetVar{
                .symbol = symbol,
                .name = mr.name,
            };
        }

        pub fn render(setvar: SetVar, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            try std.fmt.format(writer, "{s}<setvar symbol=\"{s}\" region_paddr=\"{s}\" />\n", .{ separator, setvar.symbol, setvar.name });
        }
    };

    pub const MemoryRegion = struct {
        allocator: Allocator,
        name: []const u8,
        size: u64,
        paddr: ?u64,
        page_size: ?PageSize,

        pub const Options = struct {
            page_size: ?PageSize = null,
        };

        pub const OptionsPhysical = struct {
            paddr: ?u64 = null,
            page_size: ?PageSize = null,
        };

        // TODO: change to two API:
        // MemoryRegion.virtual()
        // MemoryRegion.physical()
        pub fn create(allocator: Allocator, name: []const u8, size: u64, options: Options) MemoryRegion {
            return MemoryRegion{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not allocate name for MemoryRegion"),
                .size = size,
                .page_size = options.page_size,
                .paddr = null,
            };
        }

        /// Creates a memory region at a specific physical address. Allocates the physical address automatically.
        pub fn physical(allocator: Allocator, sdf: *SystemDescription, name: []const u8, size: u64, options: OptionsPhysical) MemoryRegion {
            const paddr = if (options.paddr) |fixed_paddr| fixed_paddr else sdf.paddr_top - size;
            // TODO: handle alignment if people specify a page size.
            if (options.paddr == null) {
                sdf.paddr_top = paddr;
            }
            return MemoryRegion{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not allocate name for MemoryRegion"),
                .size = size,
                .paddr = paddr,
                .page_size = options.page_size,
            };
        }

        pub fn destroy(mr: MemoryRegion) void {
            mr.allocator.free(mr.name);
        }

        pub fn render(mr: MemoryRegion, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            try std.fmt.format(writer, "{s}<memory_region name=\"{s}\" size=\"0x{x}\"", .{ separator, mr.name, mr.size });

            if (mr.paddr) |paddr| {
                try std.fmt.format(writer, " phys_addr=\"0x{x}\"", .{paddr});
            }

            if (mr.page_size) |page_size| {
                try std.fmt.format(writer, " page_size=\"0x{x}\"", .{page_size.toInt(sdf.arch)});
            }

            _ = try writer.write(" />\n");
        }

        pub const PageSize = enum(usize) {
            small,
            large,
            // huge,

            pub fn toInt(page_size: PageSize, arch: Arch) usize {
                // TODO: on RISC-V we are assuming that it's Sv39. For example if you
                // had a 64-bit system with Sv32, the page sizes would be different...
                switch (arch) {
                    .aarch64, .riscv64, .x86_64 => return switch (page_size) {
                        .small => 0x1000,
                        .large => 0x200000,
                        // .huge => 0x40000000,
                    },
                    .aarch32, .riscv32, .x86 => return switch (page_size) {
                        .small => 0x1000,
                        .large => 0x400000,
                        // .huge => 0x40000000,
                    },
                }
            }

            pub fn fromInt(page_size: usize, arch: Arch) !PageSize {
                switch (arch) {
                    .aarch64, .riscv64, .x86_64 => return switch (page_size) {
                        0x1000 => .small,
                        0x200000 => .large,
                        // 0x40000000 => .huge,
                        else => return error.InvalidPageSize,
                    },
                    .aarch32, .riscv32, .x86 => return switch (page_size) {
                        0x1000 => .small,
                        0x400000 => .large,
                        // 0x40000000 => .huge,
                        else => return error.InvalidPageSize,
                    },
                }
            }

            pub fn optimal(arch: Arch, region_size: u64) PageSize {
                // TODO would be better if we did some meta programming in case the
                // number of elements in PageSize change
                // if (region_size % PageSize.huge.toSize(sdf.arch) == 0) return .huge;
                if (region_size % PageSize.large.toInt(arch) == 0) return .large;

                return .small;
            }
        };
    };

    pub const Map = struct {
        mr: MemoryRegion,
        vaddr: u64,
        perms: Perms,
        cached: ?bool,
        setvar_vaddr: ?[]const u8,

        pub const Options = struct {
            cached: ?bool = null,
            setvar_vaddr: ?[]const u8 = null,
        };

        pub const Perms = packed struct {
            // TODO: check that perms are not write-only
            read: bool = false,
            write: bool = false,
            execute: bool = false,

            pub const r = Perms{ .read = true };
            pub const x = Perms{ .execute = true };
            pub const rw = Perms{ .read = true, .write = true };
            pub const rx = Perms{ .read = true, .execute = true };
            pub const wx = Perms{ .write = true, .execute = true };
            pub const rwx = Perms{ .read = true, .write = true, .execute = true };

            pub fn valid(perms: Perms) bool {
                if (!perms.read and !perms.execute and perms.write) {
                    return false;
                }

                return true;
            }

            pub fn toString(perms: Perms, buf: *[3]u8) []u8 {
                var i: u8 = 0;
                if (perms.read) {
                    buf[i] = 'r';
                    i += 1;
                }
                if (perms.write) {
                    buf[i] = 'w';
                    i += 1;
                }
                if (perms.execute) {
                    buf[i] = 'x';
                    i += 1;
                }

                std.debug.assert(i < 4);
                return buf[0..i];
            }

            pub fn fromString(str: []const u8) !Perms {
                const read_count = std.mem.count(u8, str, "r");
                const write_count = std.mem.count(u8, str, "w");
                const exec_count = std.mem.count(u8, str, "x");
                if (read_count > 1 or write_count > 1 or exec_count > 1) {
                    return error.InvalidPerms;
                }
                if (read_count == 0 and exec_count == 0 and write_count == 1) {
                    return error.InvalidPerms;
                }
                std.debug.assert(str.len == read_count + write_count + exec_count);
                var perms: Perms = .{};
                if (read_count > 0) {
                    perms.read = true;
                }
                if (write_count > 0) {
                    perms.write = true;
                }
                if (exec_count > 0) {
                    perms.execute = true;
                }

                return perms;
            }
        };

        // TODO: make vaddr optional so its easier to allocate it automatically
        pub fn create(mr: MemoryRegion, vaddr: u64, perms: Perms, options: Options) Map {
            if (!perms.valid()) {
                log.err("error creating mapping for '{s}': invalid permissions given", .{mr.name});
                @panic("todo");
            }

            return Map{
                .mr = mr,
                .vaddr = vaddr,
                .perms = perms,
                .cached = options.cached,
                .setvar_vaddr = options.setvar_vaddr,
            };
        }

        pub fn render(map: *const Map, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            var perms_buf = [_]u8{0} ** 3;
            const perms = map.perms.toString(&perms_buf);
            try std.fmt.format(writer, "{s}<map mr=\"{s}\" vaddr=\"0x{x}\" perms=\"{s}\"", .{ separator, map.mr.name, map.vaddr, perms });

            if (map.setvar_vaddr) |setvar_vaddr| {
                try std.fmt.format(writer, " setvar_vaddr=\"{s}\"", .{setvar_vaddr});
            }

            if (map.cached) |cached| {
                const cached_str = if (cached) "true" else "false";
                try std.fmt.format(writer, " cached=\"{s}\"", .{cached_str});
            }

            _ = try writer.write(" />\n");
        }
    };

    pub const VirtualMachine = struct {
        allocator: Allocator,
        name: []const u8,
        priority: ?u8,
        budget: ?u32,
        period: ?u32,
        vcpus: []const Vcpu,
        maps: ArrayList(Map),

        pub const Options = struct {
            priority: ?u8 = null,
            budget: ?u32 = null,
            period: ?u32 = null,
        };

        pub const Vcpu = struct {
            id: u8,
            /// Physical core the vCPU will run on
            cpu: ?u8 = null,
        };

        pub fn create(allocator: Allocator, name: []const u8, vcpus: []const Vcpu, options: Options) !VirtualMachine {
            var i: usize = 0;
            while (i < vcpus.len) : (i += 1) {
                var j = i + 1;
                while (j < vcpus.len) : (j += 1) {
                    if (vcpus[i].id == vcpus[j].id) {
                        return error.DuplicateVcpuId;
                    }
                }
            }

            return VirtualMachine{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not dupe VirtualMachine name"),
                .vcpus = allocator.dupe(Vcpu, vcpus) catch @panic("Could not dupe VirtualMachine vCPU list"),
                .maps = ArrayList(Map).init(allocator),
                .priority = options.priority,
                .budget = options.budget,
                .period = options.period,
            };
        }

        pub fn addMap(vm: *VirtualMachine, map: Map) void {
            vm.maps.append(map) catch @panic("Could not add Map to VirtualMachine");
        }

        pub fn destroy(vm: *VirtualMachine) void {
            vm.allocator.free(vm.vcpus);
            vm.allocator.free(vm.name);
            vm.maps.deinit();
        }

        pub fn render(vm: *VirtualMachine, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            try std.fmt.format(writer, "{s}<virtual_machine name=\"{s}\"", .{ separator, vm.name });

            if (vm.priority) |priority| {
                try std.fmt.format(writer, " priority=\"{}\"", .{priority});
            }
            if (vm.budget) |budget| {
                try std.fmt.format(writer, " budget=\"{}\"", .{budget});
            }
            if (vm.period) |period| {
                try std.fmt.format(writer, " period=\"{}\"", .{period});
            }
            _ = try writer.write(">\n");

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{separator});
            defer sdf.allocator.free(child_separator);

            for (vm.vcpus) |vcpu| {
                try std.fmt.format(writer, "{s}<vcpu id=\"{}\"", .{ child_separator, vcpu.id });
                if (vcpu.cpu) |cpu| {
                    try std.fmt.format(writer, " cpu=\"{}\"", .{cpu});
                }
                _ = try writer.write(" />\n");
            }

            for (vm.maps.items) |map| {
                try map.render(writer, child_separator);
            }

            try std.fmt.format(writer, "{s}</virtual_machine>\n", .{separator});
        }
    };

    pub const ProtectionDomain = struct {
        allocator: Allocator,
        name: []const u8,
        /// Program ELF
        program_image: ?[]const u8,
        /// Scheduling parameters
        /// The policy here is to follow the default values that Microkit uses.
        priority: ?u8,
        budget: ?u32,
        period: ?u32,
        passive: ?bool,
        stack_size: ?u32,
        /// Memory mappings
        maps: ArrayList(Map),
        /// The length of this array is bound by the maximum number of child PDs a PD can have.
        child_pds: ArrayList(*ProtectionDomain),
        /// The length of this array is bound by the maximum number of IRQs a PD can have.
        irqs: ArrayList(Irq),
        vm: ?*VirtualMachine,
        /// Keeping track of what IDs are available for channels, IRQs, etc
        channel_ids: std.bit_set.StaticBitSet(MAX_IDS),
        child_ids: std.bit_set.StaticBitSet(MAX_IDS),

        /// Whether or not ARM SMC is available
        arm_smc: ?bool,
        /// If this PD is a child of another PD, this ID identifies it to its parent PD
        child_id: ?u8,
        /// CPU core
        cpu: ?u8,

        setvars: ArrayList(SetVar),

        // Matches Microkit implementation
        const MAX_IDS: u8 = 62;
        const MAX_IRQS: u8 = MAX_IDS;
        const MAX_CHILD_PDS: u8 = MAX_IDS;

        pub const DEFAULT_PRIORITY: u8 = 100;

        pub const Options = struct {
            passive: ?bool = null,
            priority: ?u8 = null,
            budget: ?u32 = null,
            period: ?u32 = null,
            stack_size: ?u32 = null,
            arm_smc: ?bool = null,
            cpu: ?u8 = null,
        };

        pub fn create(allocator: Allocator, name: []const u8, program_image: ?[]const u8, options: Options) ProtectionDomain {
            const program_image_dupe = if (program_image) |p| allocator.dupe(u8, p) catch @panic("Could not dupe PD program_image") else null;

            return ProtectionDomain{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not dupe PD name"),
                .program_image = program_image_dupe,
                .maps = ArrayList(Map).init(allocator),
                .child_pds = ArrayList(*ProtectionDomain).initCapacity(allocator, MAX_CHILD_PDS) catch @panic("Could not allocate child_pds"),
                .irqs = ArrayList(Irq).initCapacity(allocator, MAX_IRQS) catch @panic("Could not allocate irqs"),
                .vm = null,
                .channel_ids = std.bit_set.StaticBitSet(MAX_IDS).initEmpty(),
                .child_ids = std.bit_set.StaticBitSet(MAX_IDS).initEmpty(),
                .setvars = ArrayList(SetVar).init(allocator),
                .priority = options.priority,
                .passive = options.passive,
                .budget = options.budget,
                .period = options.period,
                .arm_smc = options.arm_smc,
                .stack_size = options.stack_size,
                .child_id = null,
                .cpu = options.cpu,
            };
        }

        pub fn destroy(pd: *ProtectionDomain) void {
            pd.allocator.free(pd.name);
            if (pd.program_image) |program_image| {
                pd.allocator.free(program_image);
            }
            pd.maps.deinit();
            pd.child_pds.deinit();
            pd.irqs.deinit();
        }

        /// There may be times where PD resources with an ID, such as a channel
        /// or IRQ require a fixed ID while others do not. One example might be
        /// that an IRQ needs to be at a particular ID while the channel numbers
        /// do not matter.
        /// This function is used to allocate an ID for use by one of those
        /// resources ensuring there are no clashes or duplicates.
        pub fn allocateId(id_set: *std.bit_set.StaticBitSet(MAX_IDS), id: ?u8) !u8 {
            if (id) |chosen_id| {
                if (id_set.*.isSet(chosen_id)) {
                    log.err("attempting to allocate already allocated ID '{}' '", .{chosen_id});
                    return error.AlreadyAllocatedId;
                } else {
                    id_set.*.setValue(chosen_id, true);
                    return chosen_id;
                }
            } else {
                for (0..MAX_IDS) |i| {
                    if (!id_set.*.isSet(i)) {
                        id_set.*.setValue(i, true);
                        return @intCast(i);
                    }
                }

                return error.NoMoreIds;
            }
        }

        pub fn setVirtualMachine(pd: *ProtectionDomain, vm: *VirtualMachine) !void {
            if (pd.vm != null) return error.ProtectionDomainAlreadyHasVirtualMachine;
            pd.vm = vm;
        }

        pub fn addMap(pd: *ProtectionDomain, map: Map) void {
            pd.maps.append(map) catch @panic("Could not add Map to ProtectionDomain");
        }

        pub fn addIrq(pd: *ProtectionDomain, irq: Irq) !u8 {
            // If the IRQ ID is already set, then we check that we can allocate it with
            // the PD.
            if (irq.id) |id| {
                _ = try allocateId(&pd.channel_ids, id);
                try pd.irqs.append(irq);
                return id;
            } else {
                var irq_with_id = irq;
                irq_with_id.id = try allocateId(&pd.channel_ids, null);
                try pd.irqs.append(irq_with_id);
                return irq_with_id.id.?;
            }
        }

        pub fn addSetVar(pd: *ProtectionDomain, setvar: SetVar) void {
            pd.setvars.append(setvar) catch @panic("Could not add SetVar to ProtectionDomain");
        }

        const ChildOptions = struct {
            id: ?u8 = null,
        };

        pub fn addChild(pd: *ProtectionDomain, child: *ProtectionDomain, options: ChildOptions) !u8 {
            if (pd.child_pds.items.len == MAX_CHILD_PDS) {
                log.err("failed to add child '{s}' to parent '{s}', maximum children reached", .{ child.name, pd.name });
                return error.MaximumChildren;
            }

            pd.child_pds.appendAssumeCapacity(child);
            // Even though we check that we haven't added too many children, it is still
            // possible that allocation can fail.
            child.child_id = try allocateId(&pd.child_ids, options.id);

            return child.child_id.?;
        }

        // TODO: get rid of this extra arg?
        pub fn getMapVaddr(pd: *ProtectionDomain, mr: *const MemoryRegion) u64 {
            // TODO: should make sure we don't have a way of giving an invalid vaddr back (e.g on 32-bit systems this is more of a concern)

            // The approach for this is fairly simple and naive, we just loop
            // over all the maps and find the largest next available address.
            // We could extend this in the future to actually look for space
            // between mappings in the case they are not just sorted.
            // TODO: fix this
            const page_size = MemoryRegion.PageSize.optimal(.aarch64, mr.size).toInt(.aarch64);
            var next_vaddr: u64 = 0x20_000_000;
            for (pd.maps.items) |map| {
                if (map.vaddr >= next_vaddr) {
                    next_vaddr = map.vaddr + map.mr.size;
                    // TODO: Use builtins like @rem
                    const diff = next_vaddr % page_size;
                    if (diff != 0) {
                        // In the case the next virtual address is not page aligned, we need
                        // to increase it further.
                        next_vaddr += page_size - diff;
                    }
                }
            }

            // const padding: u64 = switch (page_size) {
            //     0x1000 => 0x1000,
            //     0x200_000 => 0x200_000,
            //     else => @panic("TODO"),
            // };

            return next_vaddr;
        }

        pub fn render(pd: *ProtectionDomain, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, id: ?u8) !void {
            // If we are given an ID, this PD is in fact a child PD and we have to
            // specify the ID for the root PD to use when referring to this child PD.

            try std.fmt.format(writer, "{s}<protection_domain name=\"{s}\"", .{ separator, pd.name });

            if (id) |id_val| {
                try std.fmt.format(writer, " id=\"{}\"", .{id_val});
            }

            if (pd.priority) |priority| {
                try std.fmt.format(writer, " priority=\"{}\"", .{priority});
            }

            if (pd.budget) |budget| {
                try std.fmt.format(writer, " budget=\"{}\"", .{budget});
            }

            if (pd.period) |period| {
                try std.fmt.format(writer, " period=\"{}\"", .{period});
            }

            if (pd.passive) |passive| {
                try std.fmt.format(writer, " passive=\"{}\"", .{passive});
            }

            if (pd.stack_size) |stack_size| {
                try std.fmt.format(writer, " stack_size=\"0x{x}\"", .{stack_size});
            }

            if (pd.arm_smc) |smc| {
                if (!sdf.arch.isArm()) {
                    log.err("set 'arm_smc' option when not targeting ARM\n", .{});
                    return error.InvalidArmSmc;
                }

                try std.fmt.format(writer, " smc=\"{}\"", .{smc});
            }

            if (pd.cpu) |cpu| {
                try std.fmt.format(writer, " cpu=\"{}\"", .{cpu});
            }

            _ = try writer.write(">\n");

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{separator});
            defer sdf.allocator.free(child_separator);
            // Add program image (if we have one)
            if (pd.program_image) |program_image| {
                try std.fmt.format(writer, "{s}<program_image path=\"{s}\" />\n", .{ child_separator, program_image });
            }
            for (pd.maps.items) |map| {
                try map.render(writer, child_separator);
            }
            for (pd.child_pds.items) |child_pd| {
                try child_pd.render(sdf, writer, child_separator, child_pd.child_id.?);
            }
            if (pd.vm) |vm| {
                try vm.render(sdf, writer, child_separator);
            }
            for (pd.irqs.items) |irq| {
                try irq.render(writer, child_separator);
            }
            for (pd.setvars.items) |setvar| {
                try setvar.render(writer, child_separator);
            }

            try std.fmt.format(writer, "{s}</protection_domain>\n", .{separator});
        }
    };

    pub const Channel = struct {
        pd_a: *ProtectionDomain,
        pd_b: *ProtectionDomain,
        pd_a_id: u8,
        pd_b_id: u8,
        pd_a_notify: ?bool,
        pd_b_notify: ?bool,
        pp: ?End,

        pub const End = enum { a, b };

        pub const Options = struct {
            pd_a_notify: ?bool = null,
            pd_b_notify: ?bool = null,
            pp: ?End = null,
            pd_a_id: ?u8 = null,
            pd_b_id: ?u8 = null,
        };

        pub fn create(pd_a: *ProtectionDomain, pd_b: *ProtectionDomain, options: Options) !Channel {
            if (std.mem.eql(u8, pd_a.name, pd_b.name)) {
                log.err("channel end PDs do not differ, PD name is '{s}'\n", .{pd_a.name});
                return error.InvalidChannel;
            }

            return .{
                .pd_a = pd_a,
                .pd_b = pd_b,
                .pd_a_id = try ProtectionDomain.allocateId(&pd_a.channel_ids, options.pd_a_id),
                .pd_b_id = try ProtectionDomain.allocateId(&pd_b.channel_ids, options.pd_b_id),
                .pd_a_notify = options.pd_a_notify,
                .pd_b_notify = options.pd_b_notify,
                .pp = options.pp,
            };
        }

        pub fn render(ch: Channel, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            const allocator = sdf.allocator;

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{separator});
            defer allocator.free(child_separator);

            try std.fmt.format(writer, "{s}<channel>\n{s}<end pd=\"{s}\" id=\"{}\"", .{ separator, child_separator, ch.pd_a.name, ch.pd_a_id });

            if (ch.pd_a_notify) |notify| {
                try std.fmt.format(writer, " notify=\"{}\"", .{notify});
            }

            if (ch.pp != null and ch.pp.? == .a) {
                _ = try writer.write(" pp=\"true\"");
            }
            _ = try writer.write(" />\n");

            try std.fmt.format(writer, "{s}<end pd=\"{s}\" id=\"{}\"", .{ child_separator, ch.pd_b.name, ch.pd_b_id });

            if (ch.pd_b_notify) |notify| {
                try std.fmt.format(writer, " notify=\"{}\"", .{notify});
            }

            if (ch.pp != null and ch.pp.? == .b) {
                _ = try writer.write(" pp=\"true\"");
            }

            try std.fmt.format(writer, " />\n{s}</channel>\n", .{separator});
        }
    };

    pub const Irq = struct {
        /// IRQ number that will be registered with seL4. That means that this
        /// number needs to map onto what seL4 observes (e.g the numbers in the
        /// device tree do not necessarily map onto what seL4 sees on ARM).
        irq: u32,
        trigger: ?Trigger,
        id: ?u8,

        pub const Trigger = enum(u8) {
            edge,
            level,
        };

        pub const Options = struct {
            trigger: ?Trigger = null,
            id: ?u8 = null,
        };

        pub fn create(irq: u32, options: Options) Irq {
            return .{ .irq = irq, .trigger = options.trigger, .id = options.id };
        }

        pub fn render(irq: *const Irq, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            // By the time we get here, something should have populated the 'id' field.
            std.debug.assert(irq.id != null);

            try std.fmt.format(writer, "{s}<irq irq=\"{}\" id=\"{}\"", .{ separator, irq.irq, irq.id.? });
            if (irq.trigger) |trigger| {
                try std.fmt.format(writer, " trigger=\"{s}\"", .{@tagName(trigger)});
            }

            _ = try writer.write(" />\n");
        }
    };

    pub fn create(allocator: Allocator, arch: Arch, paddr_top: u64) SystemDescription {
        var xml_data = ArrayList(u8).init(allocator);
        return SystemDescription{
            .allocator = allocator,
            .xml_data = xml_data,
            .xml = xml_data.writer(),
            .arch = arch,
            .pds = ArrayList(*ProtectionDomain).init(allocator),
            .mrs = ArrayList(MemoryRegion).init(allocator),
            .channels = ArrayList(Channel).init(allocator),
            .paddr_top = paddr_top,
        };
    }

    pub fn destroy(sdf: *SystemDescription) void {
        sdf.pds.deinit();
        sdf.mrs.deinit();
        sdf.channels.deinit();
        sdf.xml_data.deinit();
    }

    pub fn addChannel(sdf: *SystemDescription, channel: Channel) void {
        sdf.channels.append(channel) catch @panic("Could not add Channel to SystemDescription");
    }

    pub fn addMemoryRegion(sdf: *SystemDescription, mr: MemoryRegion) void {
        sdf.mrs.append(mr) catch @panic("Could not add MemoryRegion to SystemDescription");
    }

    pub fn addProtectionDomain(sdf: *SystemDescription, protection_domain: *ProtectionDomain) void {
        sdf.pds.append(protection_domain) catch @panic("Could not add ProtectionDomain to SystemDescription");
    }

    pub fn addPd(sdf: *SystemDescription, name: []const u8, program_image: ?[]const u8) ProtectionDomain {
        var pd = ProtectionDomain.create(sdf, name, program_image);
        sdf.addProtectionDomain(&pd);

        return pd;
    }

    pub fn findPd(sdf: *SystemDescription, name: []const u8) ?*ProtectionDomain {
        for (sdf.pds.items) |pd| {
            if (std.mem.eql(u8, name, pd.name)) {
                return pd;
            }
        }

        return null;
    }

    pub fn render(sdf: *SystemDescription) ![:0]const u8 {
        const writer = sdf.xml_data.writer();
        _ = try writer.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<system>\n");

        // Use 4-space indent for the XML
        const separator = "    ";
        for (sdf.mrs.items) |mr| {
            try mr.render(sdf, writer, separator);
        }
        for (sdf.pds.items) |pd| {
            try pd.render(sdf, writer, separator, null);
        }
        for (sdf.channels.items) |ch| {
            try ch.render(sdf, writer, separator);
        }

        // Given that this is library code, it is better for us to provide a zero-terminated
        // array of bytes for consumption by langauges like C.
        _ = try writer.write("</system>" ++ "\x00");

        return sdf.xml_data.items[0 .. sdf.xml_data.items.len - 1 :0];
    }

    pub fn print(sdf: *SystemDescription) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(try sdf.render());
        try stdout.writeAll("\n");
    }
};
