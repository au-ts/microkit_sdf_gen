/* C bindings for the sdfgen tooling */

#include <stdbool.h>
#include <stdint.h>

// Must be in sync with the 'Arch' enum definition in sdf.zig.
typedef enum {
    AARCH32 = 0,
    AARCH64 = 1,
    RISCV32 = 2,
    RISCV64 = 3,
    X86 = 4,
    X86_64 = 5,
} sdfgen_arch_t;

typedef enum {
    MAP_READ    = 0b001,
    MAP_WRITE   = 0b010,
    MAP_EXECUTE = 0b100,
} sdfgen_map_perms_t;

/* High-level system functions */
void *sdfgen_create(sdfgen_arch_t arch, uint64_t paddr_top);
void sdfgen_deinit(void *sdf);
void *sdfgen_render(void *sdf);

/*** DTB-related functionality ***/

// Parse the DTB at a given path
// Returns NULL if the path cannot be accessed or the bytes cannot be
// parsed.
void *sdfgen_dtb_parse(char *path);
void *sdfgen_dtb_parse_from_bytes(char *bytes, uint32_t size);
void *sdfgen_dtb_destroy(void *blob);

void *sdfgen_dtb_node(void *blob, char *node);

/*** Microkit abstractions ***/

void *sdfgen_add_pd(void *sdf, void *pd);
void *sdfgen_add_mr(void *sdf, void *mr);
void *sdfgen_add_channel(void *sdf, void *ch);

void *sdfgen_pd_create(char *name, char *elf);
void sdfgen_pd_destroy(void *pd);

/* Can specifiy a fixed ID  */
int8_t sdfgen_pd_add_child(void *sdf, void *child_pd, uint8_t *child_id);
uint64_t sdfgen_pd_get_map_vaddr(void *pd, void *map);
void sdfgen_pd_add_map(void *pd, void *map);
void sdfgen_pd_set_priority(void *pd, uint8_t priority);
void sdfgen_pd_set_budget(void *pd, uint32_t budget);
void sdfgen_pd_set_period(void *pd, uint32_t period);
void sdfgen_pd_set_stack_size(void *pd, uint32_t stack_size);
void sdfgen_pd_set_cpu(void *pd, uint8_t cpu);
void sdfgen_pd_set_passive(void *pd, bool passive);
bool sdfgen_pd_set_virtual_machine(void *pd, void *vm);

void *sdfgen_vm_create(char *name, void **vcpus, uint32_t num_vcpus);
void sdfgen_vm_destroy(void *vm);
void sdfgen_vm_add_map(void *vm, void *map);

void *sdfgen_vm_vcpu_create(uint8_t id, uint8_t *cpu);
void sdfgen_vm_vcpu_destroy(void *vm);

void *sdfgen_channel_create(void *pd_a, void *pd_b, uint8_t *pd_a_id, uint8_t *pd_b_id, bool *pd_a_notify, bool *pd_b_notify, uint8_t *pp);
void sdfgen_channel_destroy(void *ch);
uint8_t sdfgen_channel_get_pd_a_id(void *ch);
uint8_t sdfgen_channel_get_pd_b_id(void *ch);

typedef enum {
    IRQ_TRIGGER_EDGE = 0,
    IRQ_TRIGGER_LEVEL = 1,
} sdfgen_irq_trigger_t;

void *sdfgen_irq_create(uint32_t number, sdfgen_irq_trigger_t *trigger, uint8_t *id);

void *sdfgen_mr_create(char *name, uint64_t size);
void *sdfgen_mr_create_physical(void *sdf, char *name, uint64_t size, uint64_t *paddr);
uint64_t sdfgen_mr_get_size(void *mr);
bool sdgen_mr_get_paddr(void *mr, uint64_t *paddr);
void sdfgen_mr_destroy(void *mr);

void *sdfgen_map_create(void *mr, uint64_t vaddr, sdfgen_map_perms_t perms, bool cached);
void *sdfgen_map_destroy(void *map);

/*** sDDF ***/

typedef enum {
    SDDF_OK = 0,
    SDDF_ERROR_DUPLICATE_CLIENT = 1,
    SDDF_ERROR_INVALID_CLIENT = 2,
    SDDF_ERROR_NET_DUPLICATE_COPIER = 100,
    SDDF_ERROR_NET_DUPLICATE_MAC_ADDR = 101,
    SDDF_ERROR_NET_INVALID_MAC_ADDR = 102,
    SDDF_ERROR_NET_INVALID_OPTIONS = 103
} sdfgen_sddf_status_t;

void *sdfgen_sddf_init(char *path);

void *sdfgen_sddf_timer(void *sdf, void *device, void *driver);
void sdfgen_sddf_timer_destroy(void *system);
sdfgen_sddf_status_t sdfgen_sddf_timer_add_client(void *system, void *client);
bool sdfgen_sddf_timer_connect(void *system);
bool sdfgen_sddf_timer_serialise_config(void *system, char *output_dir);

void *sdfgen_sddf_serial(void *sdf, void *device, void *driver, void *virt_tx, void *virt_rx, bool enable_color);
sdfgen_sddf_status_t sdfgen_sddf_serial_add_client(void *system, void *client);
bool sdfgen_sddf_serial_connect(void *system);
bool sdfgen_sddf_serial_serialise_config(void *system, char *output_dir);

void *sdfgen_sddf_i2c(void *sdf, void *device, void *driver, void *virt);
void sdfgen_sddf_i2c_destroy(void *system);
sdfgen_sddf_status_t sdfgen_sddf_i2c_add_client(void *system, void *client);
bool sdfgen_sddf_i2c_connect(void *system);
bool sdfgen_sddf_i2c_serialise_config(void *system, char *output_dir);

void *sdfgen_sddf_blk(void *sdf, void *device, void *driver, void *virt);
void sdfgen_sddf_blk_destroy(void *system);
sdfgen_sddf_status_t sdfgen_sddf_blk_add_client(void *system, void *client, uint32_t partition);
bool sdfgen_sddf_blk_connect(void *system);
bool sdfgen_sddf_blk_serialise_config(void *system, char *output_dir);

void *sdfgen_sddf_net(void *sdf, void *device, void *driver, void *virt_rx, void *virt_tx, void *rx_dma_mr);
void sdfgen_sddf_net_destroy(void *system);
sdfgen_sddf_status_t sdfgen_sddf_net_add_client_with_copier(void *system, void *client, void *copier, uint8_t mac_addr[6], bool rx, bool tx);
bool sdfgen_sddf_net_connect(void *system);
bool sdfgen_sddf_net_serialise_config(void *system, char *output_dir);

void *sdfgen_sddf_gpu(void *sdf, void *device, void *driver, void *virt);
void sdfgen_sddf_gpu_destroy(void *system);
sdfgen_sddf_status_t sdfgen_sddf_gpu_add_client(void *system, void *client);
bool sdfgen_sddf_gpu_connect(void *system);
bool sdfgen_sddf_gpu_serialise_config(void *system, char *output_dir);

/*** Virtual Machine Monitor ***/
void *sdfgen_vmm(void *sdf, void *vmm_pd, void *vm, char *name, void *dtb, bool one_to_one_ram);
bool sdfgen_vmm_add_passthrough_device(void *vmm, char *name, void *device);
bool sdfgen_vmm_connect(void *vmm);

/*** LionsOS ***/

void *sdfgen_lionsos_fs_fat(void *sdf, void *fs, void *client);
bool sdfgen_lionsos_fs_fat_connect(void *system);

void *sdfgen_lionsos_fs_nfs(void *sdf, void *fs, void *client, void *net, void *net_copier, uint8_t mac_addr[6], void *serial, void *timer);
bool sdfgen_lionsos_fs_nfs_connect(void *system);
bool sdfgen_lionsos_fs_nfs_serialise_config(void *system, char *output_dir);

void *sdfgen_lionsos_fs_vmfs(void *sdf, void *fs_vm_sys, void *client, void *blk, void *virtio_device, uint32_t partition);
bool sdfgen_lionsos_fs_vmfs_connect(void *system);
bool sdfgen_lionsos_fs_vmfs_serialise_config(void *system, char *output_dir);
