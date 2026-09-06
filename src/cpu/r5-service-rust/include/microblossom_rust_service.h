#ifndef MICROBLOSSOM_RUST_SERVICE_ABI_H
#define MICROBLOSSOM_RUST_SERVICE_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MICROBLOSSOM_RUST_SERVICE_ABI_VERSION UINT32_C(3)
#define MICROBLOSSOM_RUST_SERVICE_DECODE_OK UINT16_C(0)
#define MICROBLOSSOM_RUST_SERVICE_INVALID_SYNDROME UINT16_C(2)
#define MICROBLOSSOM_RUST_SERVICE_ACCELERATOR_FAILURE UINT16_C(3)
#define MICROBLOSSOM_RUST_SERVICE_ACCELERATOR_INCOMPLETE UINT16_C(4)
#define MICROBLOSSOM_RUST_SERVICE_GRAPH_IDENTITY_BYTES 32u

typedef uint16_t (*microblossom_rust_read64)(void *context, uint16_t offset,
                                             uint64_t *value);
typedef uint16_t (*microblossom_rust_write64)(void *context, uint16_t offset,
                                              uint64_t value, uint8_t strobe);

struct microblossom_rust_mmio {
    void *context;
    microblossom_rust_read64 read64;
    microblossom_rust_write64 write64;
};

struct microblossom_rust_service_contract {
    uint32_t abi_version;
    uint16_t decode_ok_status;
    uint16_t vertex_count;
    uint16_t edge_count;
    uint16_t max_defects;
    uint16_t max_correction_edges;
    uint16_t max_mmio_operations;
    uint8_t graph_identity[MICROBLOSSOM_RUST_SERVICE_GRAPH_IDENTITY_BYTES];
    uint32_t service_workspace_bytes;
    uint32_t service_workspace_alignment;
    uint32_t primal_workspace_bytes;
    uint32_t dual_workspace_bytes;
    uint32_t materializer_workspace_bytes;
    uint32_t defect_workspace_bytes;
    uint32_t matching_workspace_bytes;
};

extern const struct microblossom_rust_service_contract
    microblossom_rust_service_contract;

uint16_t microblossom_rust_service_decode(
    const struct microblossom_rust_mmio *mmio, const uint8_t *defects_le,
    uint16_t defect_count, uint16_t *correction_edges,
    uint16_t correction_capacity, uint16_t *correction_count,
    uint16_t *operations);

#ifdef __cplusplus
}
#endif

#endif
