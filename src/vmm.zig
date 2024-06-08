const std = @import("std");
const mod_sdf = @import("sdf.zig");
const dtb = @import("dtb");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Mr = SystemDescription.MemoryRegion;
const Pd = SystemDescription.ProtectionDomain;
const Map = SystemDescription.Map;
const Vm = SystemDescription.VirtualMachine;

// TODO: handle freeing of arraylists
pub const VirtualMachineSystem = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    /// There is a one-to-one relationship between the each VMM PD
    /// and the DTB node
    vmms: std.ArrayList(*Pd),
    dtbs: std.ArrayList(*dtb.Node),

    pub fn init(allocator: Allocator, sdf: *SystemDescription) VirtualMachineSystem {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .vmms = std.ArrayList(*Pd).init(allocator),
            .dtbs = std.ArrayList(*dtb.Node).init(allocator),
        };
    }

    pub fn add(system: *VirtualMachineSystem, vmm: *Pd, vm: *Vm, guest_dtb: *dtb.Node) !void {
        // TODO: check that PD does not already have VM
        try system.vmms.append(vmm);
        try system.dtbs.append(guest_dtb);
        try vmm.addVirtualMachine(vm);
    }

    /// A currently naive approach to adding passthrough for a particular device
    /// to a virtual machine.
    /// This adds the required interrupts to be given to the VMM, and the 
    pub fn addPassthrough(_: *VirtualMachineSystem, ) !void {
        
    }

    pub fn connect(system: *VirtualMachineSystem) !void {
        var sdf = system.sdf;
        if (sdf.arch != .aarch64) {
            std.debug.print("Unsupported architecture: '{}'", .{ system.sdf.arch });
            return error.UnsupportedArch;
        }
        // TODO; get this information from the DTB of the guest
        const gic_vcpu = Mr.create(sdf, "gic_vcpu", 0x1000, 0x8040000, .small);
        sdf.addMemoryRegion(gic_vcpu);
        // TODO: I think this mapping stays the same so we only need to create it once
        // TODO: get the vaddr information from DTB
        const gic_vcpu_perms: Map.Permissions = .{ .read = true, .write = true };
        const gic_vcpu_map = Map.create(gic_vcpu, 0x8010000, gic_vcpu_perms, false, null);
        for (system.vmms.items, system.dtbs.items) |vmm, vm_dtb| {
            if (vmm.vm) |vm| {
                const memory_node = vm_dtb.child("memory@0").?;
                const memory_reg = memory_node.prop(.Reg).?;
                const memory_paddr: usize = @intCast(memory_reg[0][0]);
                std.debug.print("memory_paddr: {}\n", .{ memory_paddr });
                // TODO: should free the name at some point....
                const guest_mr_name = std.fmt.allocPrint(system.allocator, "guest_ram_{s}", .{ vm.name }) catch @panic("OOM");
                // TODO: get RAM size from the memory node from DTB
                const guest_ram_size = 1024 * 1024 * 256;
                const guest_ram_mr = Mr.create(sdf, guest_mr_name, guest_ram_size, null, Mr.PageSize.optimal(sdf, guest_ram_size));
                sdf.addMemoryRegion(guest_ram_mr);
                // TODO: vaddr should come from the memory node from DTB
                const vm_guest_ram_perms: Map.Permissions = .{ .read = true, .write = true, .execute = true };
                const vmm_guest_ram_perms: Map.Permissions = .{ .read = true, .write = true };
                const vm_guest_ram_map = Map.create(guest_ram_mr, memory_paddr, vm_guest_ram_perms, true, null);
                const vmm_guest_ram_map = Map.create(guest_ram_mr, memory_paddr, vmm_guest_ram_perms, true, "guest_ram_vaddr");
                vmm.addMap(vmm_guest_ram_map);
                vm.addMap(vm_guest_ram_map);
                vm.addMap(gic_vcpu_map);
            } else {
                return error.VmmMissingVm;
            }
            sdf.addProtectionDomain(vmm.*);
        }
    }
};

// Given a device tree node, will add the corresponding interrupts to the
// VMM PD and map the memory associated with the device to the virtual machine.
// pub fn addPassthrough(vmm: *Pd, vm: *VirtualMachine, device: *dtb.Node) !void {
// }
