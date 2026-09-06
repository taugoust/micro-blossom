#include "service.h"

#include "provider_platform.h"
#include "qshell_abi_generated.h"

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
#include "microblossom_rust_service.h"
#endif

#if defined(MICROBLOSSOM_PRODUCTION_FIRMWARE) && \
    !defined(MICROBLOSSOM_RUST_DECODER_LINKED)
#error "graph-specific production firmware requires the Rust decoder archive"
#endif
#if defined(MICROBLOSSOM_PRODUCTION_FIRMWARE) && \
    defined(MICROBLOSSOM_TEST_SMOKE_DECODER)
#error "the test-only smoke decoder is forbidden in production firmware"
#endif
#if defined(MICROBLOSSOM_RUST_SOFTWARE_ACCELERATOR_LINKED) && \
    !defined(MICROBLOSSOM_SERVICE_MODEL)
#error "the software accelerator is restricted to hosted service models"
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define REQUEST_MAGIC UINT32_C(0x314a424d)
#define RESULT_MAGIC UINT32_C(0x3152424d)
#define SERVICE_VERSION UINT16_C(1)
#define REQUEST_PREFIX_BYTES 40u
#define RESPONSE_PREFIX_BYTES 44u
#define MMIO_POLLS UINT32_C(4096)
#if defined(MICROBLOSSOM_TEST_SMOKE_DECODER)
#define MMIO_HARDWARE_INFO UINT16_C(0x000)
#define MMIO_INSTRUCTION UINT16_C(0x010)
#define MMIO_CLEAR_GROWN UINT16_C(0x018)
#define MMIO_MAXIMUM_GROWTH UINT16_C(0x020)
#define MMIO_READOUT_LOW UINT16_C(0x028)
#define MMIO_READOUT_HIGH UINT16_C(0x030)
#define ACCELERATOR_VERSION UINT32_C(0x240123c0)
#define INSTRUCTION_RESET UINT32_C(0x24)
#endif

#if !defined(CYT_PROVIDER_IDENTITY_WORD_0) || !defined(CYT_PROVIDER_IDENTITY_WORD_1) || \
    !defined(CYT_PROVIDER_IDENTITY_WORD_2) || !defined(CYT_PROVIDER_IDENTITY_WORD_3) || \
    !defined(CYT_PROVIDER_IDENTITY_WORD_4) || !defined(CYT_PROVIDER_IDENTITY_WORD_5) || \
    !defined(CYT_PROVIDER_IDENTITY_WORD_6) || !defined(CYT_PROVIDER_IDENTITY_WORD_7)
#error "The reproducible build must provide the firmware image identity"
#endif

_Static_assert(CYT_PROVIDER_MAX_PACKET_BYTES == MICROBLOSSOM_PACKET_STORAGE_BYTES,
               "firmware and provider packet storage must match");
_Static_assert(CYT_PROVIDER_MAX_PACKET_BEATS * QSHELL_BEAT_BYTES ==
                   MICROBLOSSOM_PACKET_STORAGE_BYTES,
               "provider beat and byte capacities must agree");
_Static_assert(MICROBLOSSOM_REQUEST_PAYLOAD_BYTES ==
                   REQUEST_PREFIX_BYTES + 2u * MICROBLOSSOM_MAX_DEFECTS,
               "request capacity does not match its defect bound");
_Static_assert(MICROBLOSSOM_RESPONSE_PAYLOAD_BYTES ==
                   RESPONSE_PREFIX_BYTES + 2u * MICROBLOSSOM_MAX_CORRECTION_EDGES,
               "response capacity does not match its correction bound");
_Static_assert(MICROBLOSSOM_REQUEST_PACKET_BYTES <=
                   MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES,
               "request exceeds its beat-rounded CPU storage");
_Static_assert(MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES <=
                   MICROBLOSSOM_PACKET_STORAGE_BYTES,
               "request storage exceeds provider packet storage");
_Static_assert(MICROBLOSSOM_RESPONSE_PACKET_BYTES <= MICROBLOSSOM_PACKET_STORAGE_BYTES,
               "response exceeds provider packet storage");
_Static_assert(MICROBLOSSOM_GRAPH_VIRTUAL_VERTEX_COUNT > 0u,
               "service graph must identify virtual vertices");
_Static_assert(MICROBLOSSOM_GRAPH_NONVIRTUAL_VERTEX_COUNT +
                       MICROBLOSSOM_GRAPH_VIRTUAL_VERTEX_COUNT ==
                   MICROBLOSSOM_GRAPH_VERTEX_COUNT,
               "virtual and non-virtual vertex counts must cover the graph");
_Static_assert(MICROBLOSSOM_MAX_DEFECTS >=
                   MICROBLOSSOM_GRAPH_NONVIRTUAL_VERTEX_COUNT,
               "defect storage must cover every non-virtual vertex");
_Static_assert(MICROBLOSSOM_MAX_DEFECTS <= MICROBLOSSOM_GRAPH_VERTEX_COUNT,
               "defect storage cannot exceed the graph vertex count");
_Static_assert(MICROBLOSSOM_MAX_CORRECTION_EDGES <=
                   MICROBLOSSOM_GRAPH_EDGE_COUNT,
               "correction storage cannot exceed the graph edge count");
_Static_assert(!MICROBLOSSOM_EXACT_GRAPH_CAPACITY ||
                   MICROBLOSSOM_MAX_DEFECTS ==
                       MICROBLOSSOM_GRAPH_NONVIRTUAL_VERTEX_COUNT,
               "exact service defect capacity must match the graph");
_Static_assert(!MICROBLOSSOM_EXACT_GRAPH_CAPACITY ||
                   MICROBLOSSOM_MAX_CORRECTION_EDGES ==
                       MICROBLOSSOM_GRAPH_EDGE_COUNT,
               "exact service correction capacity must match the graph");
_Static_assert(MICROBLOSSOM_VIRTUAL_VERTEX_BITMAP_BYTES ==
                   (MICROBLOSSOM_GRAPH_VERTEX_COUNT + 7u) / 8u,
               "virtual bitmap must cover exactly the graph vertex range");
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
_Static_assert(MICROBLOSSOM_RUST_SERVICE_DECODE_OK == MICROBLOSSOM_DECODE_OK,
               "Rust and C success status values must agree");
_Static_assert(MICROBLOSSOM_RUST_SERVICE_INVALID_SYNDROME ==
                   MICROBLOSSOM_DECODE_INVALID_SYNDROME,
               "Rust and C invalid-syndrome status values must agree");
_Static_assert(MICROBLOSSOM_RUST_SERVICE_ACCELERATOR_FAILURE ==
                   MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
               "Rust and C accelerator-failure status values must agree");
_Static_assert(MICROBLOSSOM_RUST_SERVICE_ACCELERATOR_INCOMPLETE ==
                   MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE,
               "Rust and C incomplete status values must agree");
_Static_assert(sizeof(struct microblossom_rust_service_contract) == 76u,
               "Rust service contract ABI size changed");
#endif

struct service_status {
    uint32_t words[16];
};

__attribute__((section(".fixture_status"), aligned(64), used))
static struct service_status resident_status;

/* Packet-sized and graph-sized storage lives in BTCM, never on the R5 stack. */
static uint8_t request_packet[MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES];
/* The provider-sized response buffer also stages a received record before its
 * declared length is checked against the smaller graph-specific request store. */
static uint8_t response_packet[MICROBLOSSOM_PACKET_STORAGE_BYTES];
static uint16_t correction_edges[MICROBLOSSOM_MAX_CORRECTION_EDGES];
static struct cyt_provider_packet_metadata request_metadata;
static struct cyt_provider_packet_metadata response_metadata;

static void record_status(uint32_t phase, uint32_t result, uint32_t detail,
                          uint32_t generation) {
    size_t index;
    for (index = 0u; index < 16u; ++index) {
        resident_status.words[index] = 0u;
    }
    resident_status.words[0] = UINT32_C(0x5352424d);
    resident_status.words[1] = MICROBLOSSOM_GRAPH_CONTRACT_VERSION;
    resident_status.words[2] = (uint32_t)sizeof(resident_status);
    resident_status.words[3] = phase;
    resident_status.words[4] = result;
    resident_status.words[5] = detail;
    resident_status.words[6] = CYT_PROVIDER_IDENTITY_WORD_0;
    resident_status.words[7] = CYT_PROVIDER_IDENTITY_WORD_1;
    resident_status.words[8] = (uint32_t)microblossom_graph_identity[0] |
                                ((uint32_t)microblossom_graph_identity[1] << 8u) |
                                ((uint32_t)microblossom_graph_identity[2] << 16u) |
                                ((uint32_t)microblossom_graph_identity[3] << 24u);
    resident_status.words[9] = generation;
    resident_status.words[10] = (uint32_t)MICROBLOSSOM_REQUEST_BEATS |
                                 ((uint32_t)MICROBLOSSOM_RESPONSE_BEATS << 16u);
    resident_status.words[15] = UINT32_C(0xc05e17ed);
}

static uint16_t load16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8u);
}

static uint32_t load32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8u) |
           ((uint32_t)bytes[2] << 16u) | ((uint32_t)bytes[3] << 24u);
}

static void store16(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8u);
}

static void store32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8u);
    bytes[2] = (uint8_t)(value >> 16u);
    bytes[3] = (uint8_t)(value >> 24u);
}

static void clear_bytes(uint8_t *bytes, size_t length) {
    while (length-- != 0u) {
        *bytes++ = 0u;
    }
}

static void clear_correction_output(uint16_t *edges, size_t edge_capacity,
                                    uint16_t *edge_count) {
    size_t index;
    const size_t bounded_capacity =
        edge_capacity < MICROBLOSSOM_MAX_CORRECTION_EDGES
            ? edge_capacity
            : MICROBLOSSOM_MAX_CORRECTION_EDGES;
    if (edge_count != (void *)0) {
        *edge_count = 0u;
    }
    if (edges != (void *)0) {
        for (index = 0u; index < bounded_capacity; ++index) {
            edges[index] = 0u;
        }
    }
}

static uint16_t decode_failure(uint16_t status, uint16_t *edges,
                               size_t edge_capacity, uint16_t *edge_count) {
    clear_correction_output(edges, edge_capacity, edge_count);
    return status;
}

static void copy_bytes(uint8_t *destination, const uint8_t *source, size_t length) {
    while (length-- != 0u) {
        *destination++ = *source++;
    }
}

static bool equal_bytes(const uint8_t *left, const uint8_t *right, size_t length) {
    while (length-- != 0u) {
        if (*left++ != *right++) {
            return false;
        }
    }
    return true;
}

static bool zero_bytes(const uint8_t *bytes, size_t length) {
    while (length-- != 0u) {
        if (*bytes++ != 0u) {
            return false;
        }
    }
    return true;
}

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
static bool rust_service_contract_matches(void) {
    const struct microblossom_rust_service_contract *contract =
        &microblossom_rust_service_contract;
    return contract->abi_version == MICROBLOSSOM_RUST_SERVICE_ABI_VERSION &&
           contract->decode_ok_status == MICROBLOSSOM_RUST_SERVICE_DECODE_OK &&
           contract->vertex_count == MICROBLOSSOM_GRAPH_VERTEX_COUNT &&
           contract->edge_count == MICROBLOSSOM_GRAPH_EDGE_COUNT &&
           contract->max_defects == MICROBLOSSOM_MAX_DEFECTS &&
           contract->max_correction_edges ==
               MICROBLOSSOM_MAX_CORRECTION_EDGES &&
           contract->max_mmio_operations == MMIO_POLLS &&
           equal_bytes(contract->graph_identity, microblossom_graph_identity,
                       MICROBLOSSOM_RUST_SERVICE_GRAPH_IDENTITY_BYTES) &&
           contract->service_workspace_bytes != 0u &&
           contract->service_workspace_alignment >= 4u &&
           (contract->service_workspace_alignment &
            (contract->service_workspace_alignment - 1u)) == 0u &&
           contract->primal_workspace_bytes != 0u &&
           contract->dual_workspace_bytes != 0u &&
           contract->materializer_workspace_bytes != 0u &&
           contract->materializer_workspace_bytes <=
               MICROBLOSSOM_MATERIALIZER_WORKSPACE_BYTES &&
           contract->defect_workspace_bytes ==
               2u * (uint32_t)MICROBLOSSOM_MAX_DEFECTS &&
           contract->matching_workspace_bytes ==
               6u * (uint32_t)MICROBLOSSOM_MAX_DEFECTS &&
           contract->service_workspace_bytes >=
               contract->primal_workspace_bytes +
                   contract->dual_workspace_bytes +
                   contract->materializer_workspace_bytes +
                   contract->defect_workspace_bytes +
                   contract->matching_workspace_bytes;
}
#endif

static bool vertex_is_virtual(uint16_t vertex) {
    return (microblossom_virtual_vertex_bitmap[vertex >> 3u] &
            (uint8_t)(UINT8_C(1) << (vertex & 7u))) != 0u;
}

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED) || \
    defined(MICROBLOSSOM_TEST_SMOKE_DECODER)
static enum cyt_provider_result read64(cyt_provider *provider, uint16_t offset,
                                       uint64_t *value) {
    struct cyt_provider_wait wait = {.polls_left = MMIO_POLLS};
    return cyt_provider_app_read64(provider, offset, value, &wait);
}

static enum cyt_provider_result write64(cyt_provider *provider, uint16_t offset,
                                        uint64_t value, uint8_t strobe) {
    struct cyt_provider_wait wait = {.polls_left = MMIO_POLLS};
    return cyt_provider_app_write64(provider, offset, value, strobe, &wait);
}
#endif

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
static uint16_t rust_read64(void *context, uint16_t offset, uint64_t *value) {
    if (context == (void *)0 || value == (void *)0) {
        return UINT16_C(1);
    }
    return read64((cyt_provider *)context, offset, value) == CYT_PROVIDER_OK
               ? UINT16_C(0)
               : UINT16_C(1);
}

static uint16_t rust_write64(void *context, uint16_t offset, uint64_t value,
                             uint8_t strobe) {
    if (context == (void *)0) {
        return UINT16_C(1);
    }
    return write64((cyt_provider *)context, offset, value, strobe) ==
                   CYT_PROVIDER_OK
               ? UINT16_C(0)
               : UINT16_C(1);
}
#endif

bool microblossom_service_provider_compatible(
    const struct cyt_provider_identity *identity) {
    return identity != (const void *)0 && identity->stream_abi == 1u &&
           identity->mmio_abi == 1u && identity->receive_depth != 0u &&
           identity->transmit_depth != 0u && identity->data_words_per_beat == 16u &&
           identity->max_packet_beats >= MICROBLOSSOM_MAX_PACKET_BEATS &&
           identity->max_packet_beats <= CYT_PROVIDER_MAX_PACKET_BEATS &&
           identity->endpoint_generation != 0u;
}

bool microblossom_service_generation_current(
    const struct cyt_provider_status *status, uint32_t binding_generation,
    uint32_t endpoint_generation) {
    return status != (const void *)0 && binding_generation != 0u &&
           endpoint_generation != 0u && status->available && status->healthy &&
           status->selected && status->generation_acknowledged && !status->aborted &&
           status->binding_generation == binding_generation &&
           status->endpoint_generation == endpoint_generation;
}

bool microblossom_service_prepare_response_metadata(
    const struct cyt_provider_packet_metadata *input,
    struct cyt_provider_packet_metadata *output) {
    size_t beat;
    uint8_t packet_id;
    if (output == (void *)0) {
        return false;
    }
    output->beat_count = 0u;
    for (beat = 0u; beat < CYT_PROVIDER_MAX_PACKET_BEATS; ++beat) {
        output->beat_id[beat] = 0u;
    }
    if (input == (const void *)0 ||
        input->beat_count != MICROBLOSSOM_REQUEST_BEATS) {
        return false;
    }
    packet_id = input->beat_id[0];
    if (packet_id >= 64u) {
        return false;
    }
    for (beat = 1u; beat < input->beat_count; ++beat) {
        if (input->beat_id[beat] != packet_id) {
            return false;
        }
    }
    output->beat_count = MICROBLOSSOM_RESPONSE_BEATS;
    for (beat = 0u; beat < output->beat_count; ++beat) {
        output->beat_id[beat] = packet_id;
    }
    return true;
}

uint16_t microblossom_service_decode(cyt_provider *provider, const uint8_t *packet,
                                     size_t length, uint16_t *edges,
                                     size_t edge_capacity, uint16_t *edge_count,
                                     uint16_t *operations) {
    uint16_t count;
    uint16_t previous = 0u;
    uint16_t index;
#if defined(MICROBLOSSOM_TEST_SMOKE_DECODER)
    uint64_t value;
    uint64_t low;
    uint64_t high;
    enum cyt_provider_result result;
    bool smoke_fixture;
#endif

    clear_correction_output(edges, edge_capacity, edge_count);
    if (operations != (void *)0) {
        *operations = 0u;
    }
    if (edge_count == (void *)0 || operations == (void *)0 || edges == (void *)0 ||
        provider == (void *)0 || packet == (const void *)0 ||
        length != MICROBLOSSOM_REQUEST_PACKET_BYTES ||
        edge_capacity < MICROBLOSSOM_MAX_CORRECTION_EDGES ||
        load32(packet + QSHELL_OFFSET_MAGIC) != QSHELL_MAGIC ||
        packet[QSHELL_OFFSET_ABI_VERSION] != QSHELL_ABI_VERSION ||
        packet[QSHELL_OFFSET_RECORD_CLASS] != QSHELL_CLASS_SYNDROME ||
        load16(packet + QSHELL_OFFSET_FLAGS) != QSHELL_FLAG_END_OF_ROUND ||
        load16(packet + QSHELL_OFFSET_HEADER_BYTES) != QSHELL_HEADER_BYTES ||
        load16(packet + QSHELL_OFFSET_RESERVED) != 0u ||
        load32(packet + QSHELL_OFFSET_PAYLOAD_BYTES) !=
            MICROBLOSSOM_REQUEST_PAYLOAD_BYTES ||
        load32(packet + QSHELL_OFFSET_SCHEMA_ID) !=
            QSHELL_SCHEMA_MICROBLOSSOM_DECODE_REQUEST ||
        load32(packet + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID) == 0u ||
        load32(packet + QSHELL_OFFSET_ROUTE_VERSION) == 0u ||
        load32(packet + QSHELL_OFFSET_RECORD_SEQUENCE) != 0u ||
        load32(packet + QSHELL_HEADER_BYTES) != REQUEST_MAGIC ||
        load16(packet + QSHELL_HEADER_BYTES + 4u) != SERVICE_VERSION ||
        !equal_bytes(packet + QSHELL_HEADER_BYTES + 8u,
                     microblossom_graph_identity, 32u)) {
        return decode_failure(MICROBLOSSOM_DECODE_MALFORMED_RECORD, edges,
                              edge_capacity, edge_count);
    }

    count = load16(packet + QSHELL_HEADER_BYTES + 6u);
    if (count > MICROBLOSSOM_MAX_DEFECTS) {
        return decode_failure(MICROBLOSSOM_DECODE_INVALID_SYNDROME, edges,
                              edge_capacity, edge_count);
    }
    for (index = 0u; index < count; ++index) {
        const uint16_t defect =
            load16(packet + QSHELL_HEADER_BYTES + REQUEST_PREFIX_BYTES + 2u * index);
        if (defect >= MICROBLOSSOM_GRAPH_VERTEX_COUNT || vertex_is_virtual(defect) ||
            (index != 0u && defect <= previous)) {
            return decode_failure(MICROBLOSSOM_DECODE_INVALID_SYNDROME, edges,
                                  edge_capacity, edge_count);
        }
        previous = defect;
    }
    if (!zero_bytes(packet + QSHELL_HEADER_BYTES + REQUEST_PREFIX_BYTES + 2u * count,
                    2u * (MICROBLOSSOM_MAX_DEFECTS - count))) {
        return decode_failure(MICROBLOSSOM_DECODE_INVALID_SYNDROME, edges,
                              edge_capacity, edge_count);
    }

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    {
        const struct microblossom_rust_mmio mmio = {
            .context = provider,
            .read64 = rust_read64,
            .write64 = rust_write64,
        };
        uint16_t rust_status;

        if (!rust_service_contract_matches()) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
        rust_status = microblossom_rust_service_decode(
            &mmio, packet + QSHELL_HEADER_BYTES + REQUEST_PREFIX_BYTES, count,
            edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, edge_count, operations);
        if (rust_status != MICROBLOSSOM_DECODE_OK) {
            if (rust_status != MICROBLOSSOM_DECODE_INVALID_SYNDROME &&
                rust_status != MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE &&
                rust_status != MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE) {
                rust_status = MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE;
            }
            return decode_failure(rust_status, edges, edge_capacity, edge_count);
        }
        if (*operations > MMIO_POLLS ||
            *edge_count > MICROBLOSSOM_MAX_CORRECTION_EDGES ||
            (count == 0u) != (*edge_count == 0u)) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
        for (index = 0u; index < *edge_count; ++index) {
            if (edges[index] >= MICROBLOSSOM_GRAPH_EDGE_COUNT ||
                (index != 0u && edges[index] <= edges[index - 1u])) {
                return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
                                      edges, edge_capacity, edge_count);
            }
        }
        for (; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
            if (edges[index] != 0u) {
                return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
                                      edges, edge_capacity, edge_count);
            }
        }
        return MICROBLOSSOM_DECODE_OK;
    }
#elif defined(MICROBLOSSOM_TEST_SMOKE_DECODER)
    smoke_fixture =
        count == 1u &&
        load16(packet + QSHELL_HEADER_BYTES + REQUEST_PREFIX_BYTES) ==
            MICROBLOSSOM_SMOKE_DEFECT_VERTEX;
    if (count != 0u && !smoke_fixture) {
        return decode_failure(MICROBLOSSOM_DECODE_UNSUPPORTED_SYNDROME, edges,
                              edge_capacity, edge_count);
    }

    result = read64(provider, MMIO_HARDWARE_INFO, &value);
    ++*operations;
    if (result != CYT_PROVIDER_OK || (uint32_t)value != ACCELERATOR_VERSION ||
        (uint32_t)(value >> 32u) != 1u) {
        return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                              edge_capacity, edge_count);
    }
    result = write64(provider, MMIO_INSTRUCTION, INSTRUCTION_RESET, 0xffu);
    ++*operations;
    if (result != CYT_PROVIDER_OK) {
        return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                              edge_capacity, edge_count);
    }
    result = read64(provider, MMIO_READOUT_LOW, &low);
    ++*operations;
    if (result != CYT_PROVIDER_OK) {
        return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                              edge_capacity, edge_count);
    }
    result = write64(provider, MMIO_CLEAR_GROWN, 0u, 0x03u);
    ++*operations;
    if (result != CYT_PROVIDER_OK) {
        return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                              edge_capacity, edge_count);
    }
    for (index = 0u; index < count; ++index) {
        const uint16_t defect =
            load16(packet + QSHELL_HEADER_BYTES + REQUEST_PREFIX_BYTES + 2u * index);
        const uint32_t instruction = ((uint32_t)defect << 17u) |
                                     ((uint32_t)index << 2u) | UINT32_C(2);
        result = write64(provider, MMIO_INSTRUCTION, instruction, 0xffu);
        ++*operations;
        if (result != CYT_PROVIDER_OK) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
    }
    if (count != 0u) {
        result = write64(provider, MMIO_MAXIMUM_GROWTH, UINT16_MAX, 0x03u);
        ++*operations;
        if (result != CYT_PROVIDER_OK) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
        result = read64(provider, MMIO_READOUT_LOW, &low);
        ++*operations;
        if (result != CYT_PROVIDER_OK) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
        result = read64(provider, MMIO_READOUT_HIGH, &high);
        ++*operations;
        if (result != CYT_PROVIDER_OK) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
        if (((high >> 48u) & UINT64_C(0xff)) == 0u) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE, edges,
                                  edge_capacity, edge_count);
        }
        result = write64(provider, MMIO_CLEAR_GROWN, 0u, 0x03u);
        ++*operations;
        if (result != CYT_PROVIDER_OK) {
            return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                                  edge_capacity, edge_count);
        }
    }

    result = write64(provider, MMIO_INSTRUCTION, INSTRUCTION_RESET, 0xffu);
    ++*operations;
    if (result != CYT_PROVIDER_OK) {
        return decode_failure(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, edges,
                              edge_capacity, edge_count);
    }
    if (smoke_fixture) {
        edges[0] = MICROBLOSSOM_SMOKE_CORRECTION_EDGE;
        *edge_count = 1u;
    }
    return MICROBLOSSOM_DECODE_OK;
#else
    if (count != 0u) {
        return MICROBLOSSOM_DECODE_UNSUPPORTED_SYNDROME;
    }
    return MICROBLOSSOM_DECODE_OK;
#endif
}

size_t microblossom_service_make_response(
    const uint8_t *input, size_t input_length, uint8_t *output,
    size_t output_capacity, uint16_t status, const uint16_t *edges,
    uint16_t edge_count, uint16_t operations) {
    size_t index;
    uint16_t request_defect_count;

    if (output != (void *)0 &&
        output_capacity >= MICROBLOSSOM_RESPONSE_PACKET_BYTES) {
        clear_bytes(output, MICROBLOSSOM_RESPONSE_PACKET_BYTES);
    }
    if (input == (const void *)0 || output == (void *)0 ||
        edges == (const void *)0 ||
        input_length != MICROBLOSSOM_REQUEST_PACKET_BYTES ||
        output_capacity < MICROBLOSSOM_RESPONSE_PACKET_BYTES) {
        return 0u;
    }
    request_defect_count = load16(input + QSHELL_HEADER_BYTES + 6u);
    if (status != MICROBLOSSOM_DECODE_OK) {
        edge_count = 0u;
    } else if (edge_count > MICROBLOSSOM_MAX_CORRECTION_EDGES ||
               (request_defect_count == 0u) != (edge_count == 0u)) {
        return 0u;
    }
    for (index = 0u; index < edge_count; ++index) {
        if (edges[index] >= MICROBLOSSOM_GRAPH_EDGE_COUNT ||
            (index != 0u && edges[index] <= edges[index - 1u])) {
            return 0u;
        }
    }

    copy_bytes(output, input, QSHELL_HEADER_BYTES);
    store32(output + QSHELL_OFFSET_MAGIC, QSHELL_MAGIC);
    output[QSHELL_OFFSET_ABI_VERSION] = QSHELL_ABI_VERSION;
    output[QSHELL_OFFSET_RECORD_CLASS] = QSHELL_CLASS_CORRECTION;
    store16(output + QSHELL_OFFSET_FLAGS, QSHELL_FLAG_END_OF_ROUND);
    store16(output + QSHELL_OFFSET_HEADER_BYTES, QSHELL_HEADER_BYTES);
    store16(output + QSHELL_OFFSET_RESERVED, 0u);
    store32(output + QSHELL_OFFSET_PAYLOAD_BYTES,
            MICROBLOSSOM_RESPONSE_PAYLOAD_BYTES);
    store32(output + QSHELL_OFFSET_SCHEMA_ID,
            QSHELL_SCHEMA_MICROBLOSSOM_DECODE_RESULT);
    store32(output + QSHELL_OFFSET_SOURCE_ENDPOINT_ID,
            load32(input + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID));
    store32(output + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID,
            load32(input + QSHELL_OFFSET_SOURCE_ENDPOINT_ID));
    store32(output + QSHELL_HEADER_BYTES, RESULT_MAGIC);
    store16(output + QSHELL_HEADER_BYTES + 4u, SERVICE_VERSION);
    store16(output + QSHELL_HEADER_BYTES + 6u, status);
    copy_bytes(output + QSHELL_HEADER_BYTES + 8u,
               microblossom_graph_identity, 32u);
    store16(output + QSHELL_HEADER_BYTES + 40u, edge_count);
    store16(output + QSHELL_HEADER_BYTES + 42u, operations);
    for (index = 0u; index < edge_count; ++index) {
        store16(output + QSHELL_HEADER_BYTES + RESPONSE_PREFIX_BYTES + 2u * index,
                edges[index]);
    }
    return MICROBLOSSOM_RESPONSE_PACKET_BYTES;
}

static void clear_packet_metadata(
    struct cyt_provider_packet_metadata *metadata) {
    size_t beat;
    metadata->beat_count = 0u;
    for (beat = 0u; beat < CYT_PROVIDER_MAX_PACKET_BEATS; ++beat) {
        metadata->beat_id[beat] = 0u;
    }
}

static void clear_job_storage(void) {
    clear_bytes(response_packet, sizeof(response_packet));
    clear_correction_output(correction_edges,
                            MICROBLOSSOM_MAX_CORRECTION_EDGES, (void *)0);
    clear_packet_metadata(&request_metadata);
    clear_packet_metadata(&response_metadata);
}

void microblossom_service_runtime_init(
    struct microblossom_service_runtime *runtime) {
    if (runtime != (void *)0) {
        clear_bytes((uint8_t *)runtime, sizeof(*runtime));
        runtime->connection = MICROBLOSSOM_SERVICE_CLOSED;
    }
    clear_job_storage();
}

static void service_unbind(struct microblossom_service_runtime *runtime) {
    runtime->connection = MICROBLOSSOM_SERVICE_OPEN_UNBOUND;
    runtime->binding_generation = 0u;
    clear_job_storage();
}

static void service_close(struct microblossom_service_runtime *runtime) {
    microblossom_service_runtime_init(runtime);
}

static void service_provider_failure(
    struct microblossom_service_runtime *runtime,
    enum cyt_provider_result result) {
    if (result == CYT_PROVIDER_UNBOUND || result == CYT_PROVIDER_QUIESCING) {
        service_unbind(runtime);
    } else {
        service_close(runtime);
    }
}

static void service_status_change(
    struct microblossom_service_runtime *runtime,
    const struct cyt_provider_status *status) {
    if (status->endpoint_generation != runtime->identity.endpoint_generation ||
        status->aborted || !status->available) {
        service_close(runtime);
    } else {
        service_unbind(runtime);
    }
}

enum microblossom_service_step_result microblossom_service_step(
    struct microblossom_service_runtime *runtime,
    const struct cyt_provider_firmware_identity *firmware) {
    enum cyt_provider_result result;
    struct cyt_provider_status status;

    if (runtime == (void *)0 || firmware == (const void *)0) {
        clear_job_storage();
        return MICROBLOSSOM_SERVICE_JOB_FAILED;
    }

    if (runtime->connection == MICROBLOSSOM_SERVICE_CLOSED) {
        cyt_provider *provider = (void *)0;
        struct cyt_provider_identity identity;
        clear_bytes((uint8_t *)&identity, sizeof(identity));
        result = cyt_provider_open(firmware, &provider, &identity);
        if (result == CYT_PROVIDER_OK && provider == (void *)0) {
            result = CYT_PROVIDER_PROTOCOL_ERROR;
        }
        if (result != CYT_PROVIDER_OK) {
            service_close(runtime);
            record_status(1u, (uint32_t)result, 0u, 0u);
            return MICROBLOSSOM_SERVICE_WAITING;
        }
        if (!microblossom_service_provider_compatible(&identity)) {
            record_status(1u, CYT_PROVIDER_ABI_MISMATCH,
                          identity.max_packet_beats,
                          identity.endpoint_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        runtime->provider = provider;
        runtime->identity = identity;
        runtime->connection = MICROBLOSSOM_SERVICE_OPEN_UNBOUND;
        runtime->binding_generation = 0u;
        record_status(2u, 0u, identity.max_packet_beats,
                      identity.endpoint_generation);
        return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
    }

    if (runtime->connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND) {
        result = cyt_provider_refresh_binding(runtime->provider);
        if (result == CYT_PROVIDER_UNBOUND || result == CYT_PROVIDER_QUIESCING) {
            return MICROBLOSSOM_SERVICE_WAITING;
        }
        if (result != CYT_PROVIDER_OK) {
            record_status(2u, (uint32_t)result, 0u,
                          runtime->identity.endpoint_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
        }
        result = cyt_provider_read_status(runtime->provider, &status);
        if (result != CYT_PROVIDER_OK) {
            record_status(2u, (uint32_t)result, 0u,
                          runtime->identity.endpoint_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
        }
        if (!microblossom_service_generation_current(
                &status, status.binding_generation,
                runtime->identity.endpoint_generation)) {
            service_status_change(runtime, &status);
            return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
        }
        result = cyt_provider_set_idle(runtime->provider, true);
        if (result != CYT_PROVIDER_OK) {
            record_status(2u, (uint32_t)result, 1u,
                          status.binding_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        runtime->binding_generation = status.binding_generation;
        if (status.quiesce_requested) {
            result = cyt_provider_ack_quiesce(runtime->provider);
            if (result != CYT_PROVIDER_OK) {
                record_status(2u, (uint32_t)result, 2u,
                              status.binding_generation);
                service_close(runtime);
                return MICROBLOSSOM_SERVICE_JOB_FAILED;
            }
            service_unbind(runtime);
            return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
        }
        runtime->connection = MICROBLOSSOM_SERVICE_BOUND;
        return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
    }

    if (runtime->connection != MICROBLOSSOM_SERVICE_BOUND ||
        runtime->binding_generation == 0u) {
        service_close(runtime);
        return MICROBLOSSOM_SERVICE_JOB_FAILED;
    }

    result = cyt_provider_read_status(runtime->provider, &status);
    if (result != CYT_PROVIDER_OK) {
        record_status(3u, (uint32_t)result, 0u,
                      runtime->binding_generation);
        service_provider_failure(runtime, result);
        return MICROBLOSSOM_SERVICE_JOB_FAILED;
    }
    if (!microblossom_service_generation_current(
            &status, runtime->binding_generation,
            runtime->identity.endpoint_generation)) {
        service_status_change(runtime, &status);
        return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
    }
    if (status.quiesce_requested) {
        result = cyt_provider_set_idle(runtime->provider, true);
        if (result == CYT_PROVIDER_OK) {
            result = cyt_provider_ack_quiesce(runtime->provider);
        }
        if (result != CYT_PROVIDER_OK) {
            record_status(3u, (uint32_t)result, 2u,
                          runtime->binding_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        service_unbind(runtime);
        return MICROBLOSSOM_SERVICE_CONNECTION_CHANGED;
    }

    {
        struct cyt_provider_wait wait = {.polls_left = 0u};
        size_t request_length = 0u;
        size_t response_length;
        uint16_t edge_count = 0u;
        uint16_t operations = 0u;
        uint16_t decode_status;

        result = cyt_provider_receive(
            runtime->provider, response_packet, sizeof(response_packet),
            &request_length, &request_metadata, &wait);
        if (result == CYT_PROVIDER_WOULD_BLOCK) {
            return MICROBLOSSOM_SERVICE_WAITING;
        }
        if (result != CYT_PROVIDER_OK) {
            record_status(3u, (uint32_t)result, 3u,
                          runtime->binding_generation);
            service_provider_failure(runtime, result);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        if (request_length > sizeof(request_packet)) {
            record_status(3u, CYT_PROVIDER_PROTOCOL_ERROR,
                          (uint32_t)request_length,
                          runtime->binding_generation);
            clear_job_storage();
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        if (!microblossom_service_prepare_response_metadata(
                &request_metadata, &response_metadata)) {
            record_status(3u, CYT_PROVIDER_PROTOCOL_ERROR,
                          (uint32_t)request_metadata.beat_count,
                          runtime->binding_generation);
            clear_job_storage();
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        copy_bytes(request_packet, response_packet, request_length);

        result = cyt_provider_set_idle(runtime->provider, false);
        if (result != CYT_PROVIDER_OK) {
            record_status(3u, (uint32_t)result, 4u,
                          runtime->binding_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        decode_status = microblossom_service_decode(
            runtime->provider, request_packet, request_length, correction_edges,
            MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count, &operations);
        response_length = microblossom_service_make_response(
            request_packet, request_length, response_packet,
            sizeof(response_packet), decode_status, correction_edges,
            edge_count, operations);

        result = cyt_provider_set_idle(runtime->provider, true);
        if (result != CYT_PROVIDER_OK) {
            record_status(3u, (uint32_t)result, 5u,
                          runtime->binding_generation);
            service_close(runtime);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        if (response_length == 0u) {
            record_status(3u, CYT_PROVIDER_PROTOCOL_ERROR, 6u,
                          runtime->binding_generation);
            clear_job_storage();
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }

        result = cyt_provider_read_status(runtime->provider, &status);
        if (result != CYT_PROVIDER_OK) {
            record_status(3u, (uint32_t)result, 7u,
                          runtime->binding_generation);
            service_provider_failure(runtime, result);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        if (!microblossom_service_generation_current(
                &status, runtime->binding_generation,
                runtime->identity.endpoint_generation)) {
            service_status_change(runtime, &status);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }

        wait.polls_left = MMIO_POLLS;
        result = cyt_provider_send(runtime->provider, response_packet,
                                   response_length, &response_metadata, &wait);
        if (result != CYT_PROVIDER_OK) {
            record_status(3u, (uint32_t)result, 8u,
                          runtime->binding_generation);
            service_provider_failure(runtime, result);
            return MICROBLOSSOM_SERVICE_JOB_FAILED;
        }
        record_status(3u, decode_status, operations,
                      runtime->binding_generation);
        clear_job_storage();
        return MICROBLOSSOM_SERVICE_RESPONSE_SENT;
    }
}

void r5_main(void) {
    static const struct cyt_provider_firmware_identity firmware = {
        .runtime_abi = 1u,
        .firmware_abi = 1u,
        .image_identity = {CYT_PROVIDER_IDENTITY_WORD_0,
                           CYT_PROVIDER_IDENTITY_WORD_1,
                           CYT_PROVIDER_IDENTITY_WORD_2,
                           CYT_PROVIDER_IDENTITY_WORD_3,
                           CYT_PROVIDER_IDENTITY_WORD_4,
                           CYT_PROVIDER_IDENTITY_WORD_5,
                           CYT_PROVIDER_IDENTITY_WORD_6,
                           CYT_PROVIDER_IDENTITY_WORD_7},
    };
    struct microblossom_service_runtime runtime;

    record_status(1u, 0u, 0u, 0u);
    cyt_provider_install_r5_transport();
    microblossom_service_runtime_init(&runtime);
    for (;;) {
        (void)microblossom_service_step(&runtime, &firmware);
    }
}

__attribute__((noreturn)) void r5_exception_trap(uint32_t exception_class,
                                                 uint32_t fault_address,
                                                 uint32_t syndrome) {
    (void)exception_class;
    (void)fault_address;
    (void)syndrome;
#if defined(__arm__)
    for (;;) {
        __asm__ volatile("dsb sy\n\twfi" ::: "memory");
    }
#else
    for (;;) {
    }
#endif
}

__attribute__((noreturn)) void r5_internal_trap(void) {
    r5_exception_trap(0u, 0u, 0u);
}
