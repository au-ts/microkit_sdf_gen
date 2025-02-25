from __future__ import annotations
import ctypes
import importlib.util
from ctypes import (
    cast, c_void_p, c_char_p, c_int8, c_uint8, c_uint16, c_uint32, c_uint64, c_bool, POINTER, byref, pointer
)
from typing import Optional, List, Tuple
from enum import IntEnum


class SddfStatus(IntEnum):
    OK = 0,
    DUPLICATE_CLIENT = 1,
    INVALID_CLIENT = 2,
    NET_DUPLICATE_COPIER = 100,
    NET_DUPLICATE_MAC_ADDR = 101,


# TOOD: double check
MapPermsType = c_uint32

libsdfgen = ctypes.CDLL(importlib.util.find_spec("csdfgen").origin)

libsdfgen.sdfgen_create.argtypes = [c_uint32, c_uint64]
libsdfgen.sdfgen_create.restype = c_void_p

libsdfgen.sdfgen_destroy.restype = None
libsdfgen.sdfgen_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_dtb_parse_from_bytes.restype = c_void_p
libsdfgen.sdfgen_dtb_parse_from_bytes.argtypes = [c_char_p, c_uint32]

libsdfgen.sdfgen_dtb_destroy.restype = None
libsdfgen.sdfgen_dtb_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_dtb_node.restype = c_void_p
libsdfgen.sdfgen_dtb_node.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_add_pd.restype = None
libsdfgen.sdfgen_add_pd.argtypes = [c_void_p, c_void_p]
libsdfgen.sdfgen_add_mr.restype = None
libsdfgen.sdfgen_add_mr.argtypes = [c_void_p, c_void_p]
libsdfgen.sdfgen_add_channel.restype = None
libsdfgen.sdfgen_add_channel.argtypes = [c_void_p, c_void_p]

libsdfgen.sdfgen_pd_set_priority.restype = None
libsdfgen.sdfgen_pd_set_priority.argtypes = [c_void_p, c_uint8]
libsdfgen.sdfgen_pd_set_budget.restype = None
libsdfgen.sdfgen_pd_set_budget.argtypes = [c_void_p, c_uint32]
libsdfgen.sdfgen_pd_set_period.restype = None
libsdfgen.sdfgen_pd_set_period.argtypes = [c_void_p, c_uint32]
libsdfgen.sdfgen_pd_set_passive.restype = None
libsdfgen.sdfgen_pd_set_passive.argtypes = [c_void_p, c_uint8]
libsdfgen.sdfgen_pd_set_stack_size.restype = None
libsdfgen.sdfgen_pd_set_stack_size.argtypes = [c_void_p, c_uint32]
libsdfgen.sdfgen_pd_set_cpu.restype = None
libsdfgen.sdfgen_pd_set_cpu.argtypes = [c_void_p, c_uint8]

libsdfgen.sdfgen_render.restype = c_char_p
libsdfgen.sdfgen_render.argtypes = [c_void_p]

libsdfgen.sdfgen_channel_create.restype = c_void_p
libsdfgen.sdfgen_channel_create.argtypes = [
    c_void_p,
    c_void_p,
    POINTER(c_uint8),
    POINTER(c_uint8),
    POINTER(c_bool),
    POINTER(c_bool),
    POINTER(c_uint8),
]
libsdfgen.sdfgen_channel_destroy.restype = None
libsdfgen.sdfgen_channel_destroy.argtypes = [c_void_p]
libsdfgen.sdfgen_channel_get_pd_a_id.restype = c_uint8
libsdfgen.sdfgen_channel_get_pd_a_id.argtypes = [c_void_p]
libsdfgen.sdfgen_channel_get_pd_b_id.restype = c_uint8
libsdfgen.sdfgen_channel_get_pd_b_id.argtypes = [c_void_p]

libsdfgen.sdfgen_map_create.restype = c_void_p
libsdfgen.sdfgen_map_create.argtypes = [c_void_p, c_uint64, MapPermsType, c_bool]
libsdfgen.sdfgen_map_destroy.restype = None
libsdfgen.sdfgen_map_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_mr_create.restype = c_void_p
libsdfgen.sdfgen_mr_create.argtypes = [c_char_p, c_uint64]
libsdfgen.sdfgen_mr_create_physical.restype = c_void_p
libsdfgen.sdfgen_mr_create_physical.argtypes = [c_char_p, c_uint64, c_uint64]
libsdfgen.sdfgen_mr_get_paddr.restype = c_bool;
libsdfgen.sdfgen_mr_get_paddr.argtypes = [c_void_p, POINTER(c_uint64)]

libsdfgen.sdfgen_mr_destroy.restype = None
libsdfgen.sdfgen_mr_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_irq_create.restype = c_void_p
libsdfgen.sdfgen_irq_create.argtypes = [c_uint32, POINTER(c_uint32), POINTER(c_uint8)]
libsdfgen.sdfgen_irq_destroy.restype = None
libsdfgen.sdfgen_irq_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_vm_create.restype = c_void_p
libsdfgen.sdfgen_vm_create.argtypes = [c_char_p, POINTER(c_void_p), c_uint32]
libsdfgen.sdfgen_vm_destroy.restype = None
libsdfgen.sdfgen_vm_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_vm_set_priority.restype = None
libsdfgen.sdfgen_vm_set_priority.argtypes = [c_void_p, c_uint8]

libsdfgen.sdfgen_vm_add_map.restype = None
libsdfgen.sdfgen_vm_add_map.argtypes = [c_void_p, c_void_p]

libsdfgen.sdfgen_vm_vcpu_create.restype = c_void_p
libsdfgen.sdfgen_vm_vcpu_create.argtypes = [c_uint8, POINTER(c_uint8)]
libsdfgen.sdfgen_vm_vcpu_destroy.restype = None
libsdfgen.sdfgen_vm_vcpu_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_pd_create.restype = c_void_p
libsdfgen.sdfgen_pd_create.argtypes = [c_char_p, c_char_p]
libsdfgen.sdfgen_pd_destroy.restype = None
libsdfgen.sdfgen_pd_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_pd_add_child.restype = c_int8
libsdfgen.sdfgen_pd_add_child.argtypes = [c_void_p, c_void_p, POINTER(c_uint8)]
libsdfgen.sdfgen_pd_add_map.restype = None
libsdfgen.sdfgen_pd_add_map.argtypes = [c_void_p, c_void_p]
libsdfgen.sdfgen_pd_add_irq.restype = c_int8
libsdfgen.sdfgen_pd_add_irq.argtypes = [c_void_p, c_void_p]

libsdfgen.sdfgen_sddf_timer.restype = c_void_p
libsdfgen.sdfgen_sddf_timer.argtypes = [c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_sddf_timer_destroy.restype = None
libsdfgen.sdfgen_sddf_timer_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_timer_add_client.restype = c_uint32
libsdfgen.sdfgen_sddf_timer_add_client.argtypes = [c_void_p, c_void_p]

libsdfgen.sdfgen_sddf_timer_connect.restype = c_bool
libsdfgen.sdfgen_sddf_timer_connect.argtypes = [c_void_p]
libsdfgen.sdfgen_sddf_timer_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_timer_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_sddf_i2c.restype = c_void_p
libsdfgen.sdfgen_sddf_i2c.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_sddf_i2c_destroy.restype = None
libsdfgen.sdfgen_sddf_i2c_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_i2c_add_client.restype = c_uint32
libsdfgen.sdfgen_sddf_i2c_add_client.argtypes = [c_void_p, c_void_p]

libsdfgen.sdfgen_sddf_i2c_connect.restype = c_bool
libsdfgen.sdfgen_sddf_i2c_connect.argtypes = [c_void_p]
libsdfgen.sdfgen_sddf_i2c_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_i2c_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_sddf_blk.restype = c_void_p
libsdfgen.sdfgen_sddf_blk.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_sddf_blk_destroy.restype = None
libsdfgen.sdfgen_sddf_blk_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_blk_add_client.restype = c_uint32
libsdfgen.sdfgen_sddf_blk_add_client.argtypes = [c_void_p, c_void_p, c_uint32]

libsdfgen.sdfgen_sddf_blk_connect.restype = c_bool
libsdfgen.sdfgen_sddf_blk_connect.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_blk_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_blk_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_sddf_serial.restype = c_void_p
libsdfgen.sdfgen_sddf_serial.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_bool]
libsdfgen.sdfgen_sddf_serial_destroy.restype = None
libsdfgen.sdfgen_sddf_serial_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_serial_add_client.restype = c_uint32
libsdfgen.sdfgen_sddf_serial_add_client.argtypes = [c_void_p, c_void_p]

libsdfgen.sdfgen_sddf_serial_connect.restype = c_bool
libsdfgen.sdfgen_sddf_serial_connect.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_serial_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_serial_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_sddf_net.restype = c_void_p
libsdfgen.sdfgen_sddf_net.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_sddf_net_destroy.restype = None
libsdfgen.sdfgen_sddf_net_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_net_add_client_with_copier.restype = c_bool
libsdfgen.sdfgen_sddf_net_add_client_with_copier.argtypes = [
    c_void_p,
    c_void_p,
    c_void_p,
    c_char_p
]

libsdfgen.sdfgen_sddf_net_connect.restype = c_bool
libsdfgen.sdfgen_sddf_net_connect.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_net_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_net_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_sddf_gpu.restype = c_void_p
libsdfgen.sdfgen_sddf_gpu.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_sddf_gpu_destroy.restype = None
libsdfgen.sdfgen_sddf_gpu_destroy.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_gpu_add_client.restype = c_uint32
libsdfgen.sdfgen_sddf_gpu_add_client.argtypes = [c_void_p, c_void_p, c_uint32]

libsdfgen.sdfgen_sddf_gpu_connect.restype = c_bool
libsdfgen.sdfgen_sddf_gpu_connect.argtypes = [c_void_p]

libsdfgen.sdfgen_sddf_gpu_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_gpu_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_vmm.restype = c_void_p
libsdfgen.sdfgen_vmm.argtypes = [
    c_void_p,
    c_void_p,
    c_void_p,
    c_void_p,
    c_uint64,
    c_bool
]
libsdfgen.sdfgen_vmm_add_passthrough_device.restype = c_bool
libsdfgen.sdfgen_vmm_add_passthrough_device.argtypes = [
    c_void_p,
    c_void_p,
]
libsdfgen.sdfgen_vmm_add_passthrough_device_regions.restype = c_bool
libsdfgen.sdfgen_vmm_add_passthrough_device_regions.argtypes = [
    c_void_p,
    c_void_p,
    POINTER(c_uint8),
    c_uint8,
]
libsdfgen.sdfgen_vmm_add_passthrough_device_irqs.argtypes = [
    c_void_p,
    c_void_p,
    POINTER(c_uint8),
    c_uint8,
]
libsdfgen.sdfgen_vmm_add_passthrough_irq.restype = c_bool
libsdfgen.sdfgen_vmm_add_passthrough_irq.argtypes = [c_void_p, c_void_p]
libsdfgen.sdfgen_vmm_add_virtio_mmio_console.restype = c_bool
libsdfgen.sdfgen_vmm_add_virtio_mmio_console.argtypes = [c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_vmm_add_virtio_mmio_blk.restype = c_bool
libsdfgen.sdfgen_vmm_add_virtio_mmio_blk.argtypes = [c_void_p, c_void_p, c_void_p, c_uint32]
libsdfgen.sdfgen_vmm_add_virtio_mmio_net.restype = c_bool
libsdfgen.sdfgen_vmm_add_virtio_mmio_net.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p, c_char_p]
libsdfgen.sdfgen_vmm_connect.restype = c_bool
libsdfgen.sdfgen_vmm_connect.argtypes = [c_void_p]
libsdfgen.sdfgen_vmm_serialise_config.restype = c_bool
libsdfgen.sdfgen_vmm_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_lionsos_fs_fat.restype = c_void_p
libsdfgen.sdfgen_lionsos_fs_fat.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p, c_uint32]
libsdfgen.sdfgen_lionsos_fs_fat_connect.restype = c_bool
libsdfgen.sdfgen_lionsos_fs_fat_connect.argtypes = [c_void_p]
libsdfgen.sdfgen_lionsos_fs_fat_serialise_config.restype = c_bool
libsdfgen.sdfgen_lionsos_fs_fat_serialise_config.argtypes = [c_void_p, c_char_p]
libsdfgen.sdfgen_lionsos_fs_nfs.restype = c_void_p
libsdfgen.sdfgen_lionsos_fs_nfs.argtypes = [
    c_void_p,
    c_void_p,
    c_void_p,
    c_void_p,
    c_void_p,
    c_char_p,
    c_void_p,
    c_void_p,
    c_char_p,
    c_char_p
]
libsdfgen.sdfgen_lionsos_fs_nfs_connect.restype = c_bool
libsdfgen.sdfgen_lionsos_fs_nfs_connect.argtypes = [c_void_p]
libsdfgen.sdfgen_lionsos_fs_nfs_serialise_config.restype = c_bool
libsdfgen.sdfgen_lionsos_fs_nfs_serialise_config.argtypes = [c_void_p, c_char_p]

libsdfgen.sdfgen_sddf_lwip.restype = c_void_p
libsdfgen.sdfgen_sddf_lwip.argtypes = [c_void_p, c_void_p, c_void_p]
libsdfgen.sdfgen_sddf_lwip_connect.restype = c_bool
libsdfgen.sdfgen_sddf_lwip_connect.argtypes = [c_void_p]
libsdfgen.sdfgen_sddf_lwip_serialise_config.restype = c_bool
libsdfgen.sdfgen_sddf_lwip_serialise_config.argtypes = [c_void_p, c_char_p]

def ffi_uint8_ptr(n: Optional[int]):
    """
    Convert an int value to a uint8_t pointer for FFI.
    If 'n' is None then we return None (which acts as a null pointer)
    """
    if n is None:
        return None

    return pointer(c_uint8(n))

def ffi_uint32_ptr(n: Optional[int]):
    """
    Convert an int value to a uint32_t pointer for FFI.
    If 'n' is None then we return None (which acts as a null pointer)
    """
    if n is None:
        return None

    return pointer(c_uint32(n))

def ffi_bool_ptr(val: Optional[bool]):
    """
    Convert a bool value to a bool pointer for FFI.
    If 'val' is None then we return None (which acts as a null pointer)
    """
    if val is None:
        return None

    return pointer(c_bool(val))


class DeviceTree:
    """
    This class exists to allow other layers to be generic to boards or architectures
    by letting the user talk about hardware via the Device Tree.
    """
    _obj: c_void_p
    _bytes: bytes

    def __init__(self, data: bytes):
        """
        Parse a Device Tree Blob (.dtb) and use it to get nodes
        for generating sDDF device classes or other components.
        """
        # Data is stored explicitly so it is not freed in GC.
        # The DTB parser assumes the memory does not go away.
        self._bytes = data
        self._obj = libsdfgen.sdfgen_dtb_parse_from_bytes(c_char_p(data), len(data))
        assert self._obj is not None

    def __del__(self):
        libsdfgen.sdfgen_dtb_destroy(self._obj)

    @property
    def size(self) -> int:
        return len(self._bytes)

    class Node:
        def __init__(self, device_tree: DeviceTree, node: str):
            c_node = c_char_p(node.encode("utf-8"))
            self._obj = libsdfgen.sdfgen_dtb_node(device_tree._obj, c_node)

            if self._obj is None:
                raise Exception(f"could not find DTB node '{node}'")

    def node(self, name: str) -> DeviceTree.Node:
        """
        Given a parsed DeviceTree, find the specific node based on the node names.
        Child nodes can be referenced by separating the parent and child node name
        by '/'.

        Example:

        .. code-block:: python

            dtb = DeviceTree(dtb_bytes)
            dtb.node("soc/timer@13050000")

        would be used to access the timer device on a Device Tree that looked like:

        .. code-block::

            soc {
                timer@13050000 {
                    ...
                };
            };
        """
        return DeviceTree.Node(self, name)


class SystemDescription:
    """
    Class for describing a Microkit system. Manages all Microkit resources such as
    Protection Domains, Memory Regions, Channels, etc.
    """

    _obj: c_void_p
    # We need to hold references to the PDs in case they get GC'd.
    # TODO: is this really necessary?
    _pds: List[ProtectionDomain]

    class Arch(IntEnum):
        """Target architecture. Used to resolve architecture specific features or attributes."""
        # Important that this aligns with sdfgen_arch_t in the C bindings.
        AARCH32 = 0,
        AARCH64 = 1,
        RISCV32 = 2,
        RISCV64 = 3,
        X86 = 4,
        X86_64 = 5,

    class ProtectionDomain:
        _name: str
        _obj: c_void_p
        # We need to hold references to the PDs in case they get GC'd.
        _child_pds: List[SystemDescription.ProtectionDomain]

        def __init__(
            self,
            name: str,
            program_image: str,
            priority: Optional[int] = None,
            budget: Optional[int] = None,
            period: Optional[int] = None,
            passive: Optional[bool] = None,
            stack_size: Optional[int] = None,
            cpu: Optional[int] = None,
        ) -> None:
            self._name = name
            c_name = c_char_p(name.encode("utf-8"))
            c_program_image = c_char_p(program_image.encode("utf-8"))
            self._obj = libsdfgen.sdfgen_pd_create(c_name, c_program_image)
            self._child_pds = []
            if priority is not None:
                libsdfgen.sdfgen_pd_set_priority(self._obj, priority)
            if budget is not None:
                libsdfgen.sdfgen_pd_set_budget(self._obj, budget)
            if period is not None:
                libsdfgen.sdfgen_pd_set_period(self._obj, period)
            if passive is not None:
                libsdfgen.sdfgen_pd_set_passive(self._obj, passive)
            if stack_size is not None:
                libsdfgen.sdfgen_pd_set_stack_size(self._obj, stack_size)
            if cpu is not None:
                libsdfgen.sdfgen_pd_set_cpu(self._obj, cpu)

        @property
        def name(self) -> str:
            return self._name

        def add_child_pd(self, child_pd: SystemDescription.ProtectionDomain, child_id=None) -> int:
            """
            Returns allocated ID for the child.
            """
            c_child_id = byref(c_uint8(child_id)) if child_id else None

            id = libsdfgen.sdfgen_pd_add_child(self._obj, child_pd._obj, c_child_id)
            if id < 0:
                raise Exception(f"failed to add child to PD '{self.name}'")

            self._child_pds.append(child_pd)

            return id

        def add_map(self, map: SystemDescription.Map):
            libsdfgen.sdfgen_pd_add_map(self._obj, map._obj)

        def add_irq(self, irq: SystemDescription.Irq) -> int:
            id = libsdfgen.sdfgen_pd_add_irq(self._obj, irq._obj)
            if id < 0:
                raise Exception(f"failed to add IRQ to PD '{self.name}'")

            return id

        def set_virtual_machine(self, vm: SystemDescription.VirtualMachine):
            ret = libsdfgen.sdfgen_pd_set_virtual_machine(self._obj, vm._obj)
            if not ret:
                raise Exception(f"ProtectionDomain '{self.name}' already has VirtualMachine")

        def __del__(self):
            libsdfgen.sdfgen_pd_destroy(self._obj)

        def __repr__(self) -> str:
            return f"ProtectionDomain({self.name})"

    # TODO: __del__ is more complicated for virtual machine since it may be owned
    # by a protection domain meaning it would result in a double free
    class VirtualMachine:
        _name: str
        _obj: c_void_p

        class Vcpu:
            def __init__(self, *, id: int, cpu: Optional[int] = None):
                self._obj = libsdfgen.sdfgen_vm_vcpu_create(id, ffi_uint8_ptr(cpu))

        def __init__(self, name: str, vcpus: List[Vcpu], priority: Optional[int] = None):
            vcpus_tuple: Tuple[c_void_p] = tuple([vcpu._obj for vcpu in vcpus])
            c_vcpus = (c_void_p * len(vcpus))(*vcpus_tuple)
            c_name = c_char_p(name.encode("utf-8"))
            self._name = name
            self._obj = libsdfgen.sdfgen_vm_create(c_name, cast(c_vcpus, POINTER(c_void_p)), len(vcpus))
            if self._obj is None:
                raise Exception("failed to create VM")
            if priority is not None:
                libsdfgen.sdfgen_vm_set_priority(self._obj, priority)

        @property
        def name(self) -> str:
            return self._name

        def add_map(self, map: SystemDescription.Map):
            libsdfgen.sdfgen_vm_add_map(self._obj, map._obj)

        def __repr__(self) -> str:
            return f"VirtualMachine({self.name})"

    class Map:
        _obj: c_void_p

        class Perms:
            def __init__(self, *, r: bool = False, w: bool = False, x: bool = False):
                self.read = r
                self.write = w
                self.execute = x

            def _to_c_bindings(self) -> int:
                c_perms = 0
                if self.read:
                    c_perms |= 0b001
                if self.write:
                    c_perms |= 0b010
                if self.execute:
                    c_perms |= 0b100

                return c_perms

        def __init__(
            self,
            mr: SystemDescription.MemoryRegion,
            vaddr: int,
            perms: Perms,
            *,
            cached: bool = True,
        ) -> None:
            self._obj = libsdfgen.sdfgen_map_create(mr._obj, vaddr, perms._to_c_bindings(), cached)
            if self._obj is None:
                raise Exception("failed to create mapping")

    class MemoryRegion:
        _obj: c_void_p

        # TODO: handle more options
        def __init__(
            self,
            name: str,
            size: int,
            *,
            paddr: Optional[int] = None
        ) -> None:
            c_name = c_char_p(name.encode("utf-8"))
            if paddr:
                self._obj = libsdfgen.sdfgen_mr_create_physical(c_name, size, paddr)
            else:
                self._obj = libsdfgen.sdfgen_mr_create(c_name, size)

        @property
        def paddr(self):
            paddr = c_uint64(0)
            has_paddr = libsdfgen.sdfgen_mr_get_paddr(self._obj, pointer(paddr))
            if has_paddr:
                return paddr
            else:
                return None

        def __del__(self):
            libsdfgen.sdfgen_mr_destroy(self._obj)

    class Irq:
        _obj: c_void_p

        class Trigger(IntEnum):
            EDGE = 0,
            LEVEL = 1,

        def __init__(
            self,
            irq: int,
            trigger: Optional[Trigger] = None,
            id: Optional[int] = None,
        ):
            self._obj = libsdfgen.sdfgen_irq_create(irq, ffi_uint32_ptr(trigger), ffi_uint8_ptr(id))
            if self._obj is None:
                raise Exception("failed to create IRQ")

        def __del__(self):
            libsdfgen.sdfgen_irq_destroy(self._obj)

    class Channel:
        _obj: c_void_p

        def __init__(
            self,
            a: SystemDescription.ProtectionDomain,
            b: SystemDescription.ProtectionDomain,
            *,
            a_id: Optional[int] = None,
            b_id: Optional[int] = None,
            pp_a: Optional[bool] = None,
            pp_b: Optional[bool] = None,
            notify_a: Optional[bool] = None,
            notify_b: Optional[bool] = None,
        ) -> None:
            c_pp = None
            if pp_a is not None:
                c_pp = 0
            elif pp_b is not None:
                c_pp = 1

            if pp_a is not None and pp_b is not None:
                raise Exception("attempting to create channel with PP on both ends")

            self._obj = libsdfgen.sdfgen_channel_create(
                a._obj,
                b._obj,
                ffi_uint8_ptr(a_id),
                ffi_uint8_ptr(b_id),
                ffi_bool_ptr(notify_a),
                ffi_bool_ptr(notify_b),
                ffi_uint8_ptr(c_pp),
            )
            if self._obj is None:
                raise Exception("failed to create channel")

        @property
        def pd_a_id(self) -> int:
            return libsdfgen.sdfgen_channel_get_pd_a_id(self._obj)

        @property
        def pd_b_id(self) -> int:
            return libsdfgen.sdfgen_channel_get_pd_b_id(self._obj)

        def __del__(self):
            libsdfgen.sdfgen_channel_destroy(self._obj)

    def __init__(self, arch: Arch, paddr_top: int) -> None:
        """
        Create a System Description
        """
        self._obj = libsdfgen.sdfgen_create(arch.value, paddr_top)
        self._pds = []

    def __del__(self):
        libsdfgen.sdfgen_destroy(self._obj)

    def add_pd(self, pd: ProtectionDomain):
        self._pds.append(pd)
        libsdfgen.sdfgen_add_pd(self._obj, pd._obj)

    def add_mr(self, mr: MemoryRegion):
        libsdfgen.sdfgen_add_mr(self._obj, mr._obj)

    def add_channel(self, ch: Channel):
        libsdfgen.sdfgen_add_channel(self._obj, ch._obj)

    def render(self) -> str:
        """
        Generate the XML view of the System Description Format for consumption by the Microkit.
        """
        return libsdfgen.sdfgen_render(self._obj).decode("utf-8")


class Sddf:
    """
    Class for creating I/O systems based on the seL4 Device Driver Framework (sDDF).

    There is a Python class for each device class (e.g Block, Network). They all follow
    the pattern of being initialised, then having clients added, and then being connected
    before the final SDF is generated.
    """
    def __init__(self, path: str):
        """
        :param path: str to the root of the sDDF source code.
        """
        ret = libsdfgen.sdfgen_sddf_init(c_char_p(path.encode("utf-8")))
        if not ret:
            # TODO: report more information
            raise Exception(f"sDDF failed to initialise with path '{path}'")

    def __del__(self):
        # TODO
        pass

    class Serial:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            device: Optional[DeviceTree.Node],
            driver: SystemDescription.ProtectionDomain,
            virt_tx: SystemDescription.ProtectionDomain,
            *,
            virt_rx: Optional[SystemDescription.ProtectionDomain] = None,
            enable_color: bool = True
        ) -> None:
            if device is None:
                device_obj = None
            else:
                device_obj = device._obj

            if virt_rx is None:
                virt_rx_obj = None
            else:
                virt_rx_obj = virt_rx._obj

            self._obj = libsdfgen.sdfgen_sddf_serial(
                sdf._obj, device_obj, driver._obj, virt_tx._obj, virt_rx_obj, c_bool(enable_color)
            )
            if self._obj is None:
                raise Exception("failed to create serial system")

        def add_client(self, client: SystemDescription.ProtectionDomain):
            """Add a new client connection to the serial system."""
            ret = libsdfgen.sdfgen_sddf_serial_add_client(self._obj, client._obj)
            if ret == SddfStatus.OK:
                return
            elif ret == SddfStatus.DUPLICATE_CLIENT:
                raise Exception(f"duplicate client given '{client}'")
            elif ret == SddfStatus.INVALID_CLIENT:
                raise Exception(f"invalid client given '{client}'")
            else:
                raise Exception(f"internal error: {ret}")

        def connect(self) -> bool:
            """
            Construct and all resources to the associated SystemDescription,
            returns whether successful.

            Must have all clients and options set before calling.

            Cannot be called more than once.
            """
            return libsdfgen.sdfgen_sddf_serial_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_serial_serialise_config(self._obj, c_output_dir)

        def __del__(self):
            libsdfgen.sdfgen_sddf_serial_destroy(self._obj)

    class I2c:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            device: Optional[DeviceTree.Node],
            driver: SystemDescription.ProtectionDomain,
            virt: SystemDescription.ProtectionDomain
        ) -> None:
            if device is None:
                device_obj = None
            else:
                device_obj = device._obj

            self._obj = libsdfgen.sdfgen_sddf_i2c(sdf._obj, device_obj, driver._obj, virt._obj)

        def add_client(self, client: SystemDescription.ProtectionDomain):
            ret = libsdfgen.sdfgen_sddf_i2c_add_client(self._obj, client._obj)
            if ret == SddfStatus.OK:
                return
            elif ret == SddfStatus.DUPLICATE_CLIENT:
                raise Exception(f"duplicate client given '{client}'")
            elif ret == SddfStatus.INVALID_CLIENT:
                raise Exception(f"invalid client given '{client}'")
            else:
                raise Exception(f"internal error: {ret}")

        def connect(self) -> bool:
            return libsdfgen.sdfgen_sddf_i2c_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_i2c_serialise_config(self._obj, c_output_dir)

        def __del__(self):
            libsdfgen.sdfgen_sddf_i2c_destroy(self._obj)

    class Blk:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            device: Optional[DeviceTree.Node],
            driver: SystemDescription.ProtectionDomain,
            virt: SystemDescription.ProtectionDomain
        ) -> None:
            if device is None:
                device_obj = None
            else:
                device_obj = device._obj

            self._obj = libsdfgen.sdfgen_sddf_blk(sdf._obj, device_obj, driver._obj, virt._obj)
            if self._obj is None:
                raise Exception("failed to create blk system")

        def add_client(self, client: SystemDescription.ProtectionDomain, *, partition: int):
            ret = libsdfgen.sdfgen_sddf_blk_add_client(self._obj, client._obj, partition)
            if ret == SddfStatus.OK:
                return
            elif ret == SddfStatus.DUPLICATE_CLIENT:
                raise Exception(f"duplicate client given '{client}'")
            elif ret == SddfStatus.INVALID_CLIENT:
                raise Exception(f"invalid client given '{client}'")
            else:
                raise Exception(f"internal error: {ret}")

        def connect(self) -> bool:
            return libsdfgen.sdfgen_sddf_blk_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_blk_serialise_config(self._obj, c_output_dir)

        def __del__(self):
            libsdfgen.sdfgen_sddf_blk_destroy(self._obj)

    class Net:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            device: Optional[DeviceTree.Node],
            driver: SystemDescription.ProtectionDomain,
            virt_tx: SystemDescription.ProtectionDomain,
            virt_rx: SystemDescription.ProtectionDomain
        ) -> None:
            if device is None:
                device_obj = None
            else:
                device_obj = device._obj

            self._obj = libsdfgen.sdfgen_sddf_net(
                sdf._obj, device_obj, driver._obj, virt_tx._obj, virt_rx._obj
            )

        def add_client_with_copier(
            self,
            client: SystemDescription.ProtectionDomain,
            copier: SystemDescription.ProtectionDomain,
            *,
            mac_addr: Optional[str] = None
        ) -> None:
            """
            Add a client connected to a copier component for RX traffic.

            :param copier: must be unique to this client, cannot be used with any other client.
            :param mac_addr: must be unique to the Network system.
            """
            if mac_addr is not None and len(mac_addr) != 17:
                raise Exception(
                    f"invalid MAC address length for client '{client.name}', {mac_addr}"
                )

            c_mac_addr = c_char_p(0)
            if mac_addr is not None:
                c_mac_addr = c_char_p(mac_addr.encode("utf-8"))
            ret = libsdfgen.sdfgen_sddf_net_add_client_with_copier(
                self._obj, client._obj, copier._obj, c_mac_addr
            )
            if ret == SddfStatus.OK:
                return
            elif ret == SddfStatus.DUPLICATE_CLIENT:
                raise Exception(f"duplicate client given '{client}'")
            elif ret == SddfStatus.INVALID_CLIENT:
                raise Exception(f"invalid client given '{client}'")
            elif ret == SddfStatus.NET_DUPLICATE_COPIER:
                raise Exception(f"duplicate copier given '{copier}'")
            elif ret == SddfStatus.NET_DUPLICATE_MAC_ADDR:
                raise Exception(f"duplicate MAC address given '{mac_addr}'")
            else:
                raise Exception(f"internal error: {ret}")

        def connect(self) -> bool:
            return libsdfgen.sdfgen_sddf_net_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_net_serialise_config(self._obj, c_output_dir)

        def __del__(self):
            libsdfgen.sdfgen_sddf_net_destroy(self._obj)

    class Timer:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            device: Optional[DeviceTree.Node],
            driver: SystemDescription.ProtectionDomain
        ) -> None:
            if device is None:
                device_obj = None
            else:
                device_obj = device._obj

            self._obj: c_void_p = libsdfgen.sdfgen_sddf_timer(sdf._obj, device_obj, driver._obj)

        def add_client(self, client: SystemDescription.ProtectionDomain):
            ret = libsdfgen.sdfgen_sddf_timer_add_client(self._obj, client._obj)
            if ret == SddfStatus.OK:
                return
            elif ret == SddfStatus.DUPLICATE_CLIENT:
                raise Exception(f"duplicate client given '{client}'")
            elif ret == SddfStatus.INVALID_CLIENT:
                raise Exception(f"invalid client given '{client}'")
            else:
                raise Exception(f"internal error: {ret}")

        def connect(self) -> bool:
            return libsdfgen.sdfgen_sddf_timer_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_timer_serialise_config(self._obj, c_output_dir)

        def __del__(self):
            libsdfgen.sdfgen_sddf_timer_destroy(self._obj)

    class Gpu:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            device: Optional[DeviceTree.Node],
            driver: SystemDescription.ProtectionDomain,
            virt: SystemDescription.ProtectionDomain
        ) -> None:
            if device is None:
                device_obj = None
            else:
                device_obj = device._obj

            self._obj = libsdfgen.sdfgen_sddf_gpu(sdf._obj, device_obj, driver._obj, virt._obj)

        def add_client(self, client: SystemDescription.ProtectionDomain):
            ret = libsdfgen.sdfgen_sddf_gpu_add_client(self._obj, client._obj)
            if ret == SddfStatus.OK:
                return
            elif ret == SddfStatus.DUPLICATE_CLIENT:
                raise Exception(f"duplicate client given '{client}'")
            elif ret == SddfStatus.INVALID_CLIENT:
                raise Exception(f"invalid client given '{client}'")
            else:
                raise Exception(f"internal error: {ret}")

        def connect(self) -> bool:
            return libsdfgen.sdfgen_sddf_gpu_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_gpu_serialise_config(self._obj, c_output_dir)

        def __del__(self):
            libsdfgen.sdfgen_sddf_gpu_destroy(self._obj)

    class Lwip:
        _obj: c_void_p

        def __init__(
            self,
            sdf: SystemDescription,
            net: Sddf.Net,
            pd: SystemDescription.ProtectionDomain
        ) -> None:
            self._obj = libsdfgen.sdfgen_sddf_lwip(sdf._obj, net._obj, pd._obj)

        def connect(self) -> bool:
            return libsdfgen.sdfgen_sddf_lwip_connect(self._obj)

        def serialise_config(self, output_dir: str) -> bool:
            c_output_dir = c_char_p(output_dir.encode("utf-8"))
            return libsdfgen.sdfgen_sddf_lwip_serialise_config(self._obj, c_output_dir)


class Vmm:
    _obj: c_void_p

    def __init__(
        self,
        sdf: SystemDescription,
        vmm: SystemDescription.ProtectionDomain,
        vm: SystemDescription.VirtualMachine,
        dtb: DeviceTree,
        *,
        one_to_one_ram: bool = False,
    ):
        self._obj = libsdfgen.sdfgen_vmm(sdf._obj, vmm._obj, vm._obj, dtb._obj, dtb.size, one_to_one_ram)

    def add_passthrough_device(
        self,
        device: DeviceTree.Node,
        *,
        regions: Optional[List[int]] = None,
        irqs: Optional[List[int]] = None
    ):
        """
        Add pass-through access to a particular device based on its DTB node.
        :param regions: list of indices into the 'reg' field of the device to be mapped in. If None
                        then every region passed through.
        :param irqs: list of indices into the 'interrupts' field of the device to be created. If None
                        then every IRQ is passed through.
        """
        if regions is None and irqs is None:
            # If the user passed None, that means we need to map everything in
            return libsdfgen.sdfgen_vmm_add_passthrough_device(self._obj, device._obj)
        elif irqs is not None:
            # Pass through specific IRQs, all regions
            c_irqs = cast((c_uint8 * len(irqs))(*irqs), POINTER(c_uint8))
            irqs_len = len(irqs)
            ret = libsdfgen.sdfgen_vmm_add_passthrough_device_irqs(self._obj, device._obj, c_irqs, irqs_len)
            ret = libsdfgen.sdfgen_vmm_add_passthrough_device_regions(self._obj, device._obj, None, 0)
        elif regions is not None:
            # Pass through specific regions, all IRQs
            c_regions = cast((c_uint8 * len(regions))(*regions), POINTER(c_uint8))
            regions_len = len(regions)
            ret = libsdfgen.sdfgen_vmm_add_passthrough_device_regions(self._obj, device._obj, c_regions, regions_len)
            ret = libsdfgen.sdfgen_vmm_add_passthrough_device_irqs(self._obj, device._obj, None, 0)
        else:
            # unreachable case
            raise Exception("internal error")

    def add_passthrough_irq(self, irq: SystemDescription.Irq):
        return libsdfgen.sdfgen_vmm_add_passthrough_irq(self._obj, irq._obj)

    def add_virtio_mmio_console(self, device: DeviceTree.Node, serial: Sddf.Serial):
        return libsdfgen.sdfgen_vmm_add_virtio_mmio_console(self._obj, device._obj, serial._obj)

    def add_virtio_mmio_blk(self, device: DeviceTree.Node, blk: Sddf.Blk, *, partition: int):
        return libsdfgen.sdfgen_vmm_add_virtio_mmio_blk(self._obj, device._obj, blk._obj, partition)

    def add_virtio_mmio_net(
        self,
        device: DeviceTree.Node,
        net: Sddf.Net,
        copier: SystemDescription.ProtectionDomain,
        *,
        mac_addr: Optional[str] = None
    ):
        if mac_addr is not None and len(mac_addr) != 17:
            raise Exception(
                f"invalid MAC address length for '{mac_addr}'"
            )

        c_mac_addr = c_char_p(0)
        if mac_addr is not None:
            c_mac_addr = c_char_p(mac_addr.encode("utf-8"))

        return libsdfgen.sdfgen_vmm_add_virtio_mmio_net(self._obj, device._obj, net._obj, copier._obj, c_mac_addr)

    def connect(self) -> bool:
        return libsdfgen.sdfgen_vmm_connect(self._obj)

    def serialise_config(self, output_dir: str) -> bool:
        c_output_dir = c_char_p(output_dir.encode("utf-8"))
        return libsdfgen.sdfgen_vmm_serialise_config(self._obj, c_output_dir)


class LionsOs:
    class FileSystem:
        class Fat:
            _obj: c_void_p

            def __init__(
                self,
                sdf: SystemDescription,
                fs: SystemDescription.ProtectionDomain,
                client: SystemDescription.ProtectionDomain,
                *,
                blk: Sddf.Blk,
                partition: int,
            ):
                assert isinstance(blk, Sddf.Blk)
                self._obj = libsdfgen.sdfgen_lionsos_fs_fat(sdf._obj, fs._obj, client._obj, blk._obj, partition)
                if self._obj is None:
                    raise Exception("failed to create FAT file system")

            def connect(self) -> bool:
                return libsdfgen.sdfgen_lionsos_fs_fat_connect(self._obj)

            def serialise_config(self, output_dir: str) -> bool:
                c_output_dir = c_char_p(output_dir.encode("utf-8"))
                return libsdfgen.sdfgen_lionsos_fs_fat_serialise_config(self._obj, c_output_dir)

        class Nfs:
            _obj: c_void_p

            def __init__(
                self,
                sdf: SystemDescription,
                fs: SystemDescription.ProtectionDomain,
                client: SystemDescription.ProtectionDomain,
                *,
                net: Sddf.Net,
                net_copier: SystemDescription.ProtectionDomain,
                mac_addr: Optional[str] = None,
                serial: Sddf.Serial,
                timer: Sddf.Timer,
                server: str,
                export_path: str,
            ):
                if mac_addr is not None and len(mac_addr) != 17:
                    raise Exception(
                        f"invalid MAC address length for client '{client.name}', {mac_addr}"
                    )

                c_mac_addr = c_char_p(0)
                if mac_addr is not None:
                    c_mac_addr = c_char_p(mac_addr.encode("utf-8"))

                # TODO: error checking on export path and server args
                c_server = c_char_p(server.encode("utf-8"))
                c_export_path = c_char_p(export_path.encode("utf-8"))

                self._obj = libsdfgen.sdfgen_lionsos_fs_nfs(
                    sdf._obj,
                    fs._obj,
                    client._obj,
                    net._obj,
                    net_copier._obj,
                    c_mac_addr,
                    serial._obj,
                    timer._obj,
                    c_server,
                    c_export_path
                )

            def connect(self) -> bool:
                return libsdfgen.sdfgen_lionsos_fs_nfs_connect(self._obj)

            def serialise_config(self, output_dir: str) -> bool:
                c_output_dir = c_char_p(output_dir.encode("utf-8"))
                return libsdfgen.sdfgen_lionsos_fs_nfs_serialise_config(self._obj, c_output_dir)
