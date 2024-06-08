const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

// TODO: for addresses should we use the word size of the *target* machine, rather than 'usize' for everything?
// TODO: indent stuff could be done better

pub const SystemDescription = struct {
    /// Store the allocator used when creating the SystemDescirption so we
    /// can later deinit everything
    allocator: Allocator,
    /// Array holding all the bytes for the XML data
    xml_data: ArrayList(u8),
    /// We use the Writer standard library API to add to this xml_data array
    xml: ArrayList(u8).Writer,
    /// There are some architecture specific options
    arch: Arch,
    /// Protection Domains that should be exported
    pds: ArrayList(ProtectionDomain),
    /// Memory Regions that should be exported
    mrs: ArrayList(MemoryRegion),
    /// Channels that should be exported
    channels: ArrayList(Channel),

    /// Supported architectures by seL4
    pub const Arch = enum(c_int) {
        aarch32,
        aarch64,
        riscv32,
        riscv64,
        x86,
        x86_64,
    };

    pub const MemoryRegion = struct {
        name: []const u8,
        size: usize,
        phys_addr: ?usize,
        page_size: PageSize,

        pub fn create(system: *SystemDescription, name: []const u8, size: usize, phys_addr: ?usize, page_size: PageSize) MemoryRegion {
            return MemoryRegion{
                .name = system.allocator.dupe(u8, name) catch "Could not allocate name for MemoryRegion",
                .size = size,
                .phys_addr = phys_addr,
                .page_size = page_size,
            };
        }

        pub fn destroy(mr: MemoryRegion, system: *SystemDescription) void {
            system.allocator.free(mr.name);
        }

        pub fn toXml(mr: MemoryRegion, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, arch: Arch) !void {
            const xml = try allocPrint(sdf.allocator, "{s}<memory_region name=\"{s}\" size=\"0x{x}\" page_size=\"0x{x}\"", .{ separator, mr.name, mr.size, mr.page_size.toSize(arch) });
            defer sdf.allocator.free(xml);

            var final_xml: []const u8 = undefined;
            if (mr.phys_addr) |phys_addr| {
                final_xml = try allocPrint(sdf.allocator, "{s} phys_addr=\"0x{x}\" />\n", .{ xml, phys_addr });
            } else {
                final_xml = try allocPrint(sdf.allocator, "{s} />\n", .{xml});
            }
            defer sdf.allocator.free(final_xml);

            _ = try writer.write(final_xml);
        }

        pub const PageSize = enum(usize) {
            small,
            large,
            huge,

            pub fn toSize(page_size: PageSize, arch: Arch) usize {
                // TODO: on RISC-V we are assuming that it's Sv39. For example if you
                // had a 64-bit system with Sv32, the page sizes would be different...
                switch (arch) {
                    .aarch64, .riscv64, .x86_64 => return switch (page_size) {
                        .small => 0x1000,
                        .large => 0x200000,
                        .huge => 0x40000000,
                    },
                    .aarch32, .riscv32, .x86 => return switch (page_size) {
                        .small => 0x1000,
                        .large => 0x400000,
                        .huge => 0x40000000,
                    },
                }
            }

            pub fn fromInt(page_size: usize, arch: Arch) !PageSize {
                switch (arch) {
                    .aarch64, .riscv64, .x86_64 => return switch (page_size) {
                        0x1000 => .small,
                        0x200000 => .large,
                        0x40000000 => .huge,
                        else => return error.InvalidPageSize,
                    },
                    .aarch32, .riscv32, .x86 => return switch (page_size) {
                        0x1000 => .small,
                        0x400000 => .large,
                        0x40000000 => .huge,
                        else => return error.InvalidPageSize,
                    },
                }
            }

            pub fn optimal(sdf: *SystemDescription, region_size: usize) PageSize {
                // @ivanv: would be better if we did some meta programming in case the
                // number of elements in PageSize change
                if (region_size % PageSize.huge.toSize(sdf.arch) == 0) return .huge;
                if (region_size % PageSize.large.toSize(sdf.arch) == 0) return .large;

                return .small;
            }
        };
    };

    pub const Map = struct {
        mr: MemoryRegion,
        vaddr: usize,
        perms: Permissions,
        cached: bool,
        // TODO: could make this a type?
        setvar_vaddr: ?[]const u8,

        pub const Permissions = packed struct {
            // TODO: the write-only mappings not being allowed
            // needs to be enforced here
            read: bool = false,
            /// On all architectures of seL4, write permissions are required
            write: bool = true,
            execute: bool = false,

            pub fn toString(perms: Permissions, buf: *[4]u8) usize {
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

                return i;
            }

            pub fn fromString(str: []const u8) Permissions {
                const read_count = std.mem.count(u8, str, "r");
                const write_count = std.mem.count(u8, str, "w");
                const exec_count = std.mem.count(u8, str, "x");
                std.debug.assert(read_count == 0 or read_count == 1);
                std.debug.assert(write_count == 0 or write_count == 1);
                std.debug.assert(exec_count == 0 or exec_count == 1);

                var perms: Permissions = .{};
                if (read_count > 0) {
                    perms.read = true;
                }
                if (exec_count > 0) {
                    perms.execute = true;
                }

                return perms;
            }
        };

        pub fn create(mr: MemoryRegion, vaddr: usize, perms: Permissions, cached: bool, setvar_vaddr: ?[]const u8) Map {
            return Map{
                .mr = mr,
                .vaddr = vaddr,
                .perms = perms,
                .cached = cached,
                .setvar_vaddr = setvar_vaddr,
            };
        }

        pub fn toXml(map: *const Map, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            const mr_str =
                \\{s}<map mr="{s}" vaddr="0x{x}" perms="{s}" cached="{s}" />
            ;
            const mr_str_with_setvar =
                \\{s}<map mr="{s}" vaddr="0x{x}" perms="{s}" cached="{s}" setvar_vaddr="{s}" />
            ;
            // TODO: use null terminated pointer from Zig?
            var perms = [_]u8{0} ** 4;
            const i = map.perms.toString(&perms);

            const cached = if (map.cached) "true" else "false";
            var xml: []const u8 = undefined;
            if (map.setvar_vaddr) |setvar_vaddr| {
                xml = try allocPrint(sdf.allocator, mr_str_with_setvar, .{ separator, map.mr.name, map.vaddr, perms[0..i], cached, setvar_vaddr });
            } else {
                xml = try allocPrint(sdf.allocator, mr_str, .{ separator, map.mr.name, map.vaddr, perms[0..i], cached });
            }
            defer sdf.allocator.free(xml);

            _ = try writer.write(xml);
            // @ivanv: come back to, try put it in a single string
            _ = try writer.write("\n");
        }
    };

    pub const VirtualMachine = struct {
        name: []const u8,
        priority: u8 = 100,
        budget: usize = 100,
        period: usize = 100,
        passive: bool = false,
        maps: ArrayList(Map),

        pub fn create(sdf: *SystemDescription, name: []const u8) *VirtualMachine {
            var vm = sdf.allocator.create(VirtualMachine) catch @panic("Could not allocate VirtualMachine");
            vm.name = name;
            vm.maps = ArrayList(Map).init(sdf.allocator);

            return vm;
        }

        pub fn addMap(vm: *VirtualMachine, map: Map) void {
            vm.maps.append(map) catch @panic("Could not add Map to VirtualMachine");
        }

        pub fn destroy(vm: *VirtualMachine) void {
            vm.maps.deinit();
        }

        pub fn toXml(vm: *VirtualMachine, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, id: usize) !void {
            const first_tag =
                \\{s}<virtual_machine name="{s}" id="{}" priority="{}" budget="{}" period="{}" passive="{}" />
            ;
            const first_xml = try allocPrint(sdf.allocator, first_tag, .{ separator, vm.name, id, vm.priority, vm.budget, vm.period, vm.passive });
            defer sdf.allocator.free(first_xml);
            _ = try writer.write(first_xml);
            _ = try writer.write("\n");

            // Add memory region mappings as child nodes
            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{ separator });
            defer sdf.allocator.free(child_separator);
            for (vm.maps.items) |map| {
                try map.toXml(sdf, writer, child_separator);
            }

            const closing_tag =
                \\{s}<virtual_machine />
            ;
            const closing_xml = try allocPrint(sdf.allocator, closing_tag, .{ separator });
            defer sdf.allocator.free(closing_xml);
            _ = try writer.write(closing_xml);
            _ = try writer.write("\n");
        }
    };

    pub const ProtectionDomain = struct {
        name: []const u8,
        /// Program ELF
        program_image: ?ProgramImage,
        /// Scheduling parameters
        /// The policy here is to follow the default values that Microkit uses.
        priority: u8 = 100,
        budget: usize = 100,
        period: usize = 100,
        passive: bool = false,
        /// Whether there is an available 'protected' entry point
        pp: bool = false,
        /// Child nodes
        maps: ArrayList(Map),
        child_pds: ArrayList(ProtectionDomain),
        irqs: ArrayList(Interrupt),
        vm: ?*VirtualMachine,
        /// Internal counter of the next available ID
        next_avail_id: usize = 0,

        pub const ProgramImage = struct {
            path: []const u8,

            pub fn create(path: []const u8) ProgramImage {
                return .{ .path = path };
            }

            pub fn toXml(program_image: *const ProgramImage, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
                const xml = try allocPrint(sdf.allocator, "{s}<program_image path=\"{s}\" />\n", .{ separator, program_image.path });
                defer sdf.allocator.free(xml);
                _ = try writer.write(xml);
            }
        };

        pub fn create(sdf: *SystemDescription, name: []const u8, program_image: ?ProgramImage) *ProtectionDomain {
            const pd = sdf.allocator.create(ProtectionDomain) catch @panic("Could not allocate ProtectionDomain");
            pd.* = ProtectionDomain{
                .name = name,
                .program_image = program_image,
                .maps = ArrayList(Map).init(sdf.allocator),
                .child_pds = ArrayList(ProtectionDomain).init(sdf.allocator),
                .irqs = ArrayList(Interrupt).init(sdf.allocator),
                .vm = null,
            };

            return pd;
        }

        pub fn destroy(pd: *ProtectionDomain) void {
            pd.maps.deinit();
            for (pd.child_pds.items) |child_pd| {
                child_pd.destroy();
            }
            pd.irqs.deinit();
        }

        pub fn addVirtualMachine(pd: *ProtectionDomain, vm: *VirtualMachine) !void {
            if (pd.vm != null) return error.ProtectionDomainAlreadyHasVirtualMachine;
            pd.vm = vm;
        }

        pub fn addMap(pd: *ProtectionDomain, map: Map) void {
            pd.maps.append(map) catch @panic("Could not add Map to ProtectionDomain");
        }

        pub fn addInterrupt(pd: *ProtectionDomain, interrupt: Interrupt) !void {
            // TODO: should check that the IRQ number does not already exist!
            // TODO: we have a maximum number of interrupts! we should be checking
            // that we do not exceed the maximum number of channel IDs
            try pd.irqs.append(interrupt);
        }

        pub fn addChild(pd: *ProtectionDomain, child: ProtectionDomain) !void {
            try pd.child_pds.append(child);
        }

        pub fn getMapableVaddr(pd: *ProtectionDomain, _: usize) usize {
            // TODO: should make sure we don't have a way of giving an invalid vaddr back (e.g on 32-bit systems this is more of a concern)

            // The approach for this is fairly simple and naive, we just loop
            // over all the maps and find the largest next available address.
            // We could extend this in the future to actually look for space
            // between mappings in the case they are not just sorted.
            var next_vaddr: usize = 0x10_000_000;
            for (pd.maps.items) |map| {
                if (map.vaddr >= next_vaddr) {
                    next_vaddr = map.vaddr + map.mr.size;
                }
            }

            return next_vaddr;
        }

        pub fn toXml(pd: *ProtectionDomain, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, id: ?usize) !void {
            // If we are given an ID, this PD is in fact a child PD and we have to
            // specify the ID for the root PD to use when referring to this child PD.
            // TODO: simplify this whole logic, it's quite messy right now
            const attributes_str =
                \\priority="{}" budget="{}" period="{}" passive="{}" pp="{}"
            ;
            const attributes_xml = try allocPrint(sdf.allocator, attributes_str, .{ pd.priority, pd.budget, pd.period, pd.passive, pd.pp });
            defer sdf.allocator.free(attributes_xml);
            var top: []const u8 = undefined;
            if (id) |id_val| {
                top = try allocPrint(sdf.allocator, "{s}<protection_domain name=\"{s}\" id=\"{}\" {s}>\n", .{ separator, pd.name, id_val, attributes_xml });
            } else {
                top = try allocPrint(sdf.allocator, "{s}<protection_domain name=\"{s}\" {s}>\n", .{ separator, pd.name, attributes_xml });
            }
            defer sdf.allocator.free(top);
            _ = try writer.write(top);

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{ separator });
            defer sdf.allocator.free(child_separator);
            // Add program image (if we have one)
            if (pd.program_image) |program_image| {
                try program_image.toXml(sdf, writer, child_separator);
            }
            // Add memory region mappins
            for (pd.maps.items) |map| {
                try map.toXml(sdf, writer, child_separator);
            }
            // Add child PDs
            for (pd.child_pds.items) |*child_pd| {
                try child_pd.toXml(sdf, writer, child_separator, pd.next_avail_id);
                pd.next_avail_id += 1;
            }
            // Add virtual machine (if we have one)
            if (pd.vm) |vm| {
                try vm.toXml(sdf, writer, child_separator, pd.next_avail_id);
                pd.next_avail_id += 1;
            }
            // Add interrupts
            for (pd.irqs.items) |irq| {
                try irq.toXml(sdf, writer, child_separator, pd.next_avail_id);
                pd.next_avail_id += 1;
            }

            const bottom = try allocPrint(sdf.allocator, "{s}</protection_domain>\n", .{ separator });
            defer sdf.allocator.free(bottom);
            _ = try writer.write(bottom);
        }
    };

    pub const Channel = struct {
        pd1_name: []const u8,
        pd2_name: []const u8,
        pd1_end_id: usize,
        pd2_end_id: usize,

        pub fn create(pd1: *ProtectionDomain, pd2: *ProtectionDomain) Channel {
            const ch = Channel{
                .pd1_name = pd1.name,
                .pd2_name = pd2.name,
                .pd1_end_id = pd1.next_avail_id,
                .pd2_end_id = pd2.next_avail_id,
            };
            pd1.next_avail_id += 1;
            pd2.next_avail_id += 1;

            return ch;
        }

        pub fn toXml(ch: Channel, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{ separator });
            defer sdf.allocator.free(child_separator);
            const channel_str =
                \\{s}<channel>{s}{s}<end pd="{s}" id="{}" />{s}{s}<end pd="{s}" id="{}" />{s}{s}</channel>
            ;
            const channel_xml = try allocPrint(sdf.allocator, channel_str, .{ separator, "\n", child_separator, ch.pd1_name, ch.pd1_end_id, "\n", child_separator, ch.pd2_name, ch.pd2_end_id, "\n", separator });
            defer sdf.allocator.free(channel_xml);

            _ = try writer.write(channel_xml);
            _ = try writer.write("\n");
        }
    };

    pub const Interrupt = struct {
        fixed_id: ?usize = null,
        /// IRQ number that will be registered with seL4. That means that this
        /// number needs to map onto what seL4 observes (e.g the numbers in the
        /// device tree do not necessarily map onto what seL4 sees on ARM).
        irq: usize,
        // TODO: there is a potential edge-case. There exist platforms
        // supported by seL4 that do not allow for an IRQ trigger to be set.
        trigger: Trigger,

        pub const Trigger = enum { edge, level };

        pub fn create(irq: usize, trigger: Trigger, id: ?usize) Interrupt {
            // TODO: if there's a fixed id then we need to check it's not allocated already
            // TODO: the XML export of a PD also needs to consider the fixed IDs
            return Interrupt{ .irq = irq, .trigger = trigger, .fixed_id = id };
        }

        pub fn toXml(irq: *const Interrupt, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, id: usize) !void {
            const irq_str =
                \\{s}<irq irq="{}" trigger="{s}" id="{}" />
            ;
            const irq_id = if (irq.fixed_id) |irq_fixed_id| irq_fixed_id else id;
            const irq_xml = try allocPrint(sdf.allocator, irq_str, .{ separator, irq.irq, @tagName(irq.trigger), irq_id });
            defer sdf.allocator.free(irq_xml);

            _ = try writer.write(irq_xml);
            _ = try writer.write("\n");
        }
    };

    pub fn create(allocator: Allocator, arch: Arch) !SystemDescription {
        var xml_data = ArrayList(u8).init(allocator);
        return SystemDescription{
            .allocator = allocator,
            .xml_data = xml_data,
            .xml = xml_data.writer(),
            .arch = arch,
            .pds = ArrayList(ProtectionDomain).init(allocator),
            .mrs = ArrayList(MemoryRegion).init(allocator),
            .channels = ArrayList(Channel).init(allocator),
        };
    }

    pub fn destroy(sdf: *SystemDescription) void {
        for (sdf.pds.items) |pd| {
            pd.destroy();
            sdf.allocator.destroy(pd);
        }
        sdf.pds.deinit();
        for (sdf.mrs.items) |mr| mr.destroy(sdf);
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

    pub fn addProtectionDomain(sdf: *SystemDescription, pd: ProtectionDomain) void {
        sdf.pds.append(pd) catch |e| {
            std.debug.print("{}\n", .{ e });
            @panic("Could not add ProtectionDomain to SystemDescription");
        };
    }

    pub fn toXml(sdf: *SystemDescription) ![:0]const u8 {
        const writer = sdf.xml_data.writer();
        _ = try writer.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<system>\n");

        // Use 4-space indent for the XML
        const separator = "    ";
        for (sdf.mrs.items) |mr| {
            try mr.toXml(sdf, writer, separator, sdf.arch);
        }
        for (sdf.pds.items) |*pd| {
            try pd.toXml(sdf, writer, separator, null);
        }
        for (sdf.channels.items) |ch| {
            try ch.toXml(sdf, writer, separator);
        }

        // Given that this is library code, it is better for us to provide a zero-terminated
        // array of bytes for consumption by langauges like C.
        _ = try writer.write("</system>\n" ++ "\x00");

        return sdf.xml_data.items[0..sdf.xml_data.items.len-1:0];
    }

    /// Export the necessary #defines for channel IDs, IRQ IDs and child
    /// PD IDs.
    pub fn exportCHeader(sdf: *SystemDescription, pd: *ProtectionDomain) ![]const u8 {
        var header = try allocPrint(sdf.allocator, "", .{});
        for (sdf.channels.items) |ch| {
            if (!std.mem.eql(u8, ch.pd1_name, pd.name) and !std.mem.eql(u8, ch.pd2_name, pd.name)) continue;

            const ch_id = if (std.mem.eql(u8, ch.pd1_name, pd.name)) ch.pd1_end_id else ch.pd2_end_id;
            const ch_pd_name = if (std.mem.eql(u8, ch.pd1_name, pd.name)) ch.pd2_name else ch.pd1_name;
            header = try allocPrint(sdf.allocator, "{s}#define {s}_CH {}\n", .{ header, ch_pd_name, ch_id });
        }
        // for (pd.irqs.items) |irq| {
        //     header = try allocPrint(sdf.allocator, "{s}#define IRQ {}\n", .{ header, irq.irq });
        //     header = try allocPrint(sdf.allocator, "{s}#define IRQ_CH {}\n", .{ header, irq.id });
        // }

        return header;
    }
};
