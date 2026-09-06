#include "service.h"

#include "qshell_abi_generated.h"

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
#include "microblossom_rust_service.h"
#endif

#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned reads;
static unsigned writes;
static unsigned mmio_calls;
static unsigned fail_mmio_call;
static bool accelerator_complete = true;
static enum cyt_provider_result next_mmio_result = CYT_PROVIDER_OK;
static uint8_t packet[MICROBLOSSOM_PACKET_STORAGE_BYTES];
static uint8_t response[MICROBLOSSOM_PACKET_STORAGE_BYTES];
static uint16_t edges[MICROBLOSSOM_MAX_CORRECTION_EDGES];

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
#if !defined(MICROBLOSSOM_RUST_SOFTWARE_ACCELERATOR_LINKED)
#error "The Rust-linked hosted model requires the real software accelerator"
#endif

struct mmio_trace_entry {
    uint64_t value;
    uint16_t offset;
    uint8_t strobe;
    bool write;
};

static void *software_accelerator;
static struct mmio_trace_entry mmio_trace[4096];
static size_t mmio_trace_count;
static unsigned reenter_mmio_call;
static bool reentered;
static uint16_t reentrant_edges[MICROBLOSSOM_MAX_CORRECTION_EDGES];
static uint16_t reentrant_edge_count;
static uint16_t reentrant_operations;
static uint16_t reentrant_status;

extern void *microblossom_rust_software_accelerator_create(void);
extern void microblossom_rust_software_accelerator_destroy(void *context);
extern uint16_t microblossom_rust_software_accelerator_read64(
    void *context, uint16_t offset, uint64_t *value);
extern uint16_t microblossom_rust_software_accelerator_write64(
    void *context, uint16_t offset, uint64_t value, uint8_t strobe);
extern uint16_t microblossom_rust_software_accelerator_set_identity_fault(
    void *context, uint16_t fault);
extern uint16_t microblossom_rust_software_accelerator_set_stuck_growth(
    void *context, uint16_t stuck);
extern uint16_t microblossom_rust_software_accelerator_edge(
    uint16_t edge_index, uint16_t *left, uint16_t *right, uint16_t *weight);

void print_char(char value) {
    (void)value;
}
#endif

static uint16_t get16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8u);
}

static uint32_t get32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8u) |
           ((uint32_t)bytes[2] << 16u) | ((uint32_t)bytes[3] << 24u);
}

static void put16(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8u);
}

static void put32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8u);
    bytes[2] = (uint8_t)(value >> 16u);
    bytes[3] = (uint8_t)(value >> 24u);
}

static bool is_virtual(uint16_t vertex) {
    return (microblossom_virtual_vertex_bitmap[vertex >> 3u] &
            (uint8_t)(UINT8_C(1) << (vertex & 7u))) != 0u;
}

static uint16_t nonvirtual_vertex(size_t ordinal) {
    uint16_t vertex;
    for (vertex = 0u; vertex < MICROBLOSSOM_GRAPH_VERTEX_COUNT; ++vertex) {
        if (!is_virtual(vertex)) {
            if (ordinal == 0u) {
                return vertex;
            }
            --ordinal;
        }
    }
    assert(false);
    return 0u;
}

static void fill_edges(uint16_t value) {
    size_t index;
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        edges[index] = value;
    }
}

static void assert_failure_cleared(uint16_t edge_count) {
    size_t index;
    assert(edge_count == 0u);
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        assert(edges[index] == 0u);
    }
}

static void reset_mmio(void) {
    reads = 0u;
    writes = 0u;
    mmio_calls = 0u;
    fail_mmio_call = 0u;
    accelerator_complete = true;
    next_mmio_result = CYT_PROVIDER_OK;
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    if (software_accelerator != (void *)0) {
        microblossom_rust_software_accelerator_destroy(software_accelerator);
    }
    software_accelerator = microblossom_rust_software_accelerator_create();
    assert(software_accelerator != (void *)0);
    memset(mmio_trace, 0, sizeof(mmio_trace));
    memset(reentrant_edges, UINT8_C(0x55), sizeof(reentrant_edges));
    mmio_trace_count = 0u;
    reenter_mmio_call = 0u;
    reentered = false;
    reentrant_edge_count = UINT16_MAX;
    reentrant_operations = UINT16_MAX;
    reentrant_status = UINT16_MAX;
#endif
}

static void build_request(uint16_t defect_count) {
    uint16_t vertex;
    uint16_t written = 0u;
    memset(packet, 0, sizeof(packet));
    put32(packet + QSHELL_OFFSET_MAGIC, QSHELL_MAGIC);
    packet[QSHELL_OFFSET_ABI_VERSION] = QSHELL_ABI_VERSION;
    packet[QSHELL_OFFSET_RECORD_CLASS] = QSHELL_CLASS_SYNDROME;
    put16(packet + QSHELL_OFFSET_FLAGS, QSHELL_FLAG_END_OF_ROUND);
    put16(packet + QSHELL_OFFSET_HEADER_BYTES, QSHELL_HEADER_BYTES);
    put32(packet + QSHELL_OFFSET_PAYLOAD_BYTES,
          MICROBLOSSOM_REQUEST_PAYLOAD_BYTES);
    put32(packet + QSHELL_OFFSET_CONTEXT_ID, UINT32_C(0x1234));
    put32(packet + QSHELL_OFFSET_ROUND_ID, UINT32_C(9));
    put32(packet + QSHELL_OFFSET_SCHEMA_ID,
          QSHELL_SCHEMA_MICROBLOSSOM_DECODE_REQUEST);
    put32(packet + QSHELL_OFFSET_SOURCE_ENDPOINT_ID, UINT32_C(7));
    put32(packet + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID, UINT32_C(9));
    put32(packet + QSHELL_OFFSET_ROUTE_CAPABILITY_ID, UINT32_C(11));
    put32(packet + QSHELL_OFFSET_ROUTE_VERSION, UINT32_C(13));
    put32(packet + QSHELL_OFFSET_RECORD_SEQUENCE, 0u);
    put32(packet + QSHELL_HEADER_BYTES, UINT32_C(0x314a424d));
    put16(packet + QSHELL_HEADER_BYTES + 4u, 1u);
    put16(packet + QSHELL_HEADER_BYTES + 6u, defect_count);
    memcpy(packet + QSHELL_HEADER_BYTES + 8u, microblossom_graph_identity, 32u);
    for (vertex = 0u;
         vertex < MICROBLOSSOM_GRAPH_VERTEX_COUNT && written < defect_count;
         ++vertex) {
        if (!is_virtual(vertex)) {
            put16(packet + QSHELL_HEADER_BYTES + 40u + 2u * written, vertex);
            ++written;
        }
    }
}

static void build_request_defects(const uint16_t *defects,
                                  uint16_t defect_count) {
    uint16_t index;
    build_request(defect_count);
    assert(defect_count == 0u || defects != (const void *)0);
    for (index = 0u; index < defect_count; ++index) {
        put16(packet + QSHELL_HEADER_BYTES + 40u + 2u * index, defects[index]);
    }
}

static enum cyt_provider_result take_mmio_result(void) {
    enum cyt_provider_result result;
    ++mmio_calls;
    if (fail_mmio_call != 0u && mmio_calls != fail_mmio_call) {
        return CYT_PROVIDER_OK;
    }
    result = next_mmio_result;
    next_mmio_result = CYT_PROVIDER_OK;
    fail_mmio_call = 0u;
    return result;
}

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
static void maybe_reenter_decoder(void) {
    if (!reentered && reenter_mmio_call != 0u &&
        mmio_calls == reenter_mmio_call) {
        reentered = true;
        reentrant_status = microblossom_service_decode(
            (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
            reentrant_edges, MICROBLOSSOM_MAX_CORRECTION_EDGES,
            &reentrant_edge_count, &reentrant_operations);
    }
}
#endif

enum cyt_provider_result cyt_provider_app_read64(
    cyt_provider *provider, uint16_t offset, uint64_t *value,
    struct cyt_provider_wait *wait) {
    enum cyt_provider_result result;
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    assert(value != (void *)0);
    assert(wait != (void *)0 && wait->polls_left == 4096u);
    ++reads;
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    assert(mmio_trace_count < sizeof(mmio_trace) / sizeof(mmio_trace[0]));
    mmio_trace[mmio_trace_count].offset = offset;
    mmio_trace[mmio_trace_count].write = false;
    ++mmio_trace_count;
#endif
    result = take_mmio_result();
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    maybe_reenter_decoder();
#endif
    if (result != CYT_PROVIDER_OK) {
        return result;
    }
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    if (microblossom_rust_software_accelerator_read64(
            software_accelerator, offset, value) != 0u) {
        return CYT_PROVIDER_BUS_ERROR;
    }
    mmio_trace[mmio_trace_count - 1u].value = *value;
#else
    if (offset == 0u) {
        *value = (UINT64_C(1) << 32u) | UINT32_C(0x240123c0);
    } else if (offset == 0x30u) {
        *value = accelerator_complete ? UINT64_C(1) << 48u : 0u;
    } else {
        *value = 0u;
    }
#endif
    return CYT_PROVIDER_OK;
}

enum cyt_provider_result cyt_provider_app_write64(
    cyt_provider *provider, uint16_t offset, uint64_t value, uint8_t strobe,
    struct cyt_provider_wait *wait) {
    enum cyt_provider_result result;
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    assert(wait != (void *)0 && wait->polls_left == 4096u);
    ++writes;
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    assert(mmio_trace_count < sizeof(mmio_trace) / sizeof(mmio_trace[0]));
    mmio_trace[mmio_trace_count].offset = offset;
    mmio_trace[mmio_trace_count].value = value;
    mmio_trace[mmio_trace_count].strobe = strobe;
    mmio_trace[mmio_trace_count].write = true;
    ++mmio_trace_count;
#endif
    result = take_mmio_result();
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    maybe_reenter_decoder();
#endif
    if (result != CYT_PROVIDER_OK) {
        return result;
    }
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    if (microblossom_rust_software_accelerator_write64(
            software_accelerator, offset, value, strobe) != 0u) {
        return CYT_PROVIDER_BUS_ERROR;
    }
#endif
    return CYT_PROVIDER_OK;
}

struct provider_mock {
    enum cyt_provider_result open_result;
    enum cyt_provider_result refresh_result;
    enum cyt_provider_result status_result;
    enum cyt_provider_result receive_result;
    enum cyt_provider_result send_result;
    enum cyt_provider_result busy_result;
    enum cyt_provider_result idle_result;
    enum cyt_provider_result quiesce_result;
    struct cyt_provider_identity identity;
    struct cyt_provider_status status;
    struct cyt_provider_status changed_status;
    struct cyt_provider_packet_metadata receive_metadata;
    size_t receive_length;
    size_t receive_capacity;
    unsigned change_status_read;
    unsigned open_calls;
    unsigned refresh_calls;
    unsigned status_calls;
    unsigned receive_calls;
    unsigned send_calls;
    unsigned busy_calls;
    unsigned idle_calls;
    unsigned quiesce_calls;
    size_t sent_length;
    uint16_t sent_decode_status;
    uint16_t sent_edge_count;
};

static struct provider_mock mock;
static uint8_t sent_packet[MICROBLOSSOM_PACKET_STORAGE_BYTES];

static const struct cyt_provider_firmware_identity test_firmware = {
    .runtime_abi = 1u,
    .firmware_abi = 1u,
    .image_identity = {0u},
};

static void reset_provider_mock(void) {
    size_t beat;
    memset(&mock, 0, sizeof(mock));
    memset(sent_packet, 0, sizeof(sent_packet));
    mock.open_result = CYT_PROVIDER_OK;
    mock.refresh_result = CYT_PROVIDER_OK;
    mock.status_result = CYT_PROVIDER_OK;
    mock.receive_result = CYT_PROVIDER_WOULD_BLOCK;
    mock.send_result = CYT_PROVIDER_OK;
    mock.busy_result = CYT_PROVIDER_OK;
    mock.idle_result = CYT_PROVIDER_OK;
    mock.quiesce_result = CYT_PROVIDER_OK;
    mock.identity.protocol_version = 1u;
    mock.identity.stream_abi = 1u;
    mock.identity.mmio_abi = 1u;
    mock.identity.receive_depth = 4u;
    mock.identity.transmit_depth = 4u;
    mock.identity.max_packet_beats = CYT_PROVIDER_MAX_PACKET_BEATS;
    mock.identity.data_words_per_beat = 16u;
    mock.identity.endpoint_generation = 7u;
    mock.status.endpoint_generation = 7u;
    mock.status.binding_generation = 11u;
    mock.status.available = true;
    mock.status.healthy = true;
    mock.status.selected = true;
    mock.status.generation_acknowledged = true;
    mock.receive_length = MICROBLOSSOM_REQUEST_PACKET_BYTES;
    mock.receive_metadata.beat_count = MICROBLOSSOM_REQUEST_BEATS;
    for (beat = 0u; beat < mock.receive_metadata.beat_count; ++beat) {
        mock.receive_metadata.beat_id[beat] = 17u;
    }
}

void cyt_provider_install_r5_transport(void) {}

enum cyt_provider_result cyt_provider_open(
    const struct cyt_provider_firmware_identity *firmware, cyt_provider **provider,
    struct cyt_provider_identity *identity) {
    ++mock.open_calls;
    assert(firmware != (const void *)0);
    if (mock.open_result == CYT_PROVIDER_OK) {
        *provider = (cyt_provider *)(uintptr_t)1u;
        *identity = mock.identity;
    }
    return mock.open_result;
}

enum cyt_provider_result cyt_provider_refresh_binding(cyt_provider *provider) {
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    ++mock.refresh_calls;
    return mock.refresh_result;
}

enum cyt_provider_result cyt_provider_read_status(
    cyt_provider *provider, struct cyt_provider_status *status) {
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    ++mock.status_calls;
    if (mock.status_result != CYT_PROVIDER_OK) {
        return mock.status_result;
    }
    if (mock.change_status_read != 0u &&
        mock.status_calls == mock.change_status_read) {
        mock.status = mock.changed_status;
    }
    *status = mock.status;
    return CYT_PROVIDER_OK;
}

enum cyt_provider_result cyt_provider_receive(
    cyt_provider *provider, void *buffer, size_t capacity, size_t *length,
    struct cyt_provider_packet_metadata *metadata, struct cyt_provider_wait *wait) {
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    assert(wait != (void *)0);
    ++mock.receive_calls;
    mock.receive_capacity = capacity;
    if (mock.receive_result != CYT_PROVIDER_OK) {
        return mock.receive_result;
    }
    if (capacity < mock.receive_length) {
        return CYT_PROVIDER_BUFFER_TOO_SMALL;
    }
    memcpy(buffer, packet, mock.receive_length);
    *length = mock.receive_length;
    *metadata = mock.receive_metadata;
    return CYT_PROVIDER_OK;
}

enum cyt_provider_result cyt_provider_send(
    cyt_provider *provider, const void *buffer, size_t length,
    const struct cyt_provider_packet_metadata *metadata,
    struct cyt_provider_wait *wait) {
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    assert(metadata != (const void *)0);
    assert(wait != (void *)0 && wait->polls_left != 0u);
    ++mock.send_calls;
    if (mock.send_result != CYT_PROVIDER_OK) {
        return mock.send_result;
    }
    assert(length <= sizeof(sent_packet));
    memcpy(sent_packet, buffer, length);
    mock.sent_length = length;
    mock.sent_decode_status = get16(sent_packet + QSHELL_HEADER_BYTES + 6u);
    mock.sent_edge_count = get16(sent_packet + QSHELL_HEADER_BYTES + 40u);
    return CYT_PROVIDER_OK;
}

enum cyt_provider_result cyt_provider_set_idle(cyt_provider *provider, bool idle) {
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    if (idle) {
        ++mock.idle_calls;
        return mock.idle_result;
    }
    ++mock.busy_calls;
    return mock.busy_result;
}

enum cyt_provider_result cyt_provider_ack_quiesce(cyt_provider *provider) {
    assert(provider == (cyt_provider *)(uintptr_t)1u);
    ++mock.quiesce_calls;
    return mock.quiesce_result;
}

enum cyt_provider_result cyt_provider_report_fault(cyt_provider *provider,
                                                    uint16_t code,
                                                    uint16_t detail) {
    (void)provider;
    (void)code;
    (void)detail;
    return CYT_PROVIDER_OK;
}

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
static uint16_t production_singleton_operations;

static void assert_success_trace(uint16_t operations, uint16_t expected_operations) {
    static const uint16_t exact_aperture[] = {
        UINT16_C(0x000), UINT16_C(0x008), UINT16_C(0x010), UINT16_C(0x018),
        UINT16_C(0x020), UINT16_C(0x028), UINT16_C(0x030),
    };
    bool seen[sizeof(exact_aperture) / sizeof(exact_aperture[0])] = {false};
    size_t index;
    size_t aperture_index;

    if (expected_operations != 0u) {
        assert(operations == expected_operations);
    }
    assert(mmio_calls == operations);
    assert(mmio_trace_count == operations);
    assert(reads + writes == operations);
    assert(operations >= 14u);
    assert(!mmio_trace[0].write && mmio_trace[0].offset == UINT16_C(0x000));
    assert(!mmio_trace[1].write && mmio_trace[1].offset == UINT16_C(0x008));
    assert(mmio_trace[2].write && mmio_trace[2].offset == UINT16_C(0x010));
    assert(mmio_trace[2].value == UINT32_C(0x24));
    assert(mmio_trace[2].strobe == UINT8_C(0xff));
    assert(mmio_trace[operations - 4u].write &&
           mmio_trace[operations - 4u].offset == UINT16_C(0x010) &&
           mmio_trace[operations - 4u].value == UINT32_C(0x24) &&
           mmio_trace[operations - 4u].strobe == UINT8_C(0xff));
    assert(!mmio_trace[operations - 3u].write &&
           mmio_trace[operations - 3u].offset == UINT16_C(0x028));
    assert(!mmio_trace[operations - 2u].write &&
           mmio_trace[operations - 2u].offset == UINT16_C(0x030));
    assert(mmio_trace[operations - 1u].write &&
           mmio_trace[operations - 1u].offset == UINT16_C(0x018) &&
           mmio_trace[operations - 1u].value == 0u &&
           mmio_trace[operations - 1u].strobe == UINT8_C(0x03));

    for (index = 0u; index < operations; ++index) {
        for (aperture_index = 0u;
             aperture_index < sizeof(exact_aperture) / sizeof(exact_aperture[0]);
             ++aperture_index) {
            if (mmio_trace[index].offset == exact_aperture[aperture_index]) {
                seen[aperture_index] = true;
                break;
            }
        }
        assert(aperture_index <
               sizeof(exact_aperture) / sizeof(exact_aperture[0]));
        if (mmio_trace[index].write) {
            if (mmio_trace[index].offset == UINT16_C(0x010)) {
                assert(mmio_trace[index].strobe == UINT8_C(0xff));
            } else {
                assert(mmio_trace[index].offset == UINT16_C(0x018) ||
                       mmio_trace[index].offset == UINT16_C(0x020));
                assert(mmio_trace[index].strobe == UINT8_C(0x03));
            }
        }
    }
    for (index = 0u; index < sizeof(seen) / sizeof(seen[0]); ++index) {
        assert(seen[index]);
    }
}

static void assert_semantic_correction(const uint16_t *defects,
                                       uint16_t defect_count,
                                       uint16_t edge_count,
                                       uint32_t minimum_weight) {
    uint8_t syndrome[MICROBLOSSOM_VIRTUAL_VERTEX_BITMAP_BYTES];
    uint32_t total_weight = 0u;
    uint16_t defect_index = 0u;
    uint16_t index;
    uint16_t vertex;

    memset(syndrome, 0, sizeof(syndrome));
    assert((defect_count == 0u) == (edge_count == 0u));
    for (index = 0u; index < edge_count; ++index) {
        uint16_t left;
        uint16_t right;
        uint16_t weight;
        assert(index == 0u || edges[index - 1u] < edges[index]);
        assert(microblossom_rust_software_accelerator_edge(
                   edges[index], &left, &right, &weight) == 0u);
        assert(left < MICROBLOSSOM_GRAPH_VERTEX_COUNT);
        assert(right < MICROBLOSSOM_GRAPH_VERTEX_COUNT);
        if (!is_virtual(left)) {
            syndrome[left >> 3u] ^= (uint8_t)(UINT8_C(1) << (left & 7u));
        }
        if (!is_virtual(right)) {
            syndrome[right >> 3u] ^= (uint8_t)(UINT8_C(1) << (right & 7u));
        }
        total_weight += weight;
    }
    for (vertex = 0u; vertex < MICROBLOSSOM_GRAPH_VERTEX_COUNT; ++vertex) {
        const bool actual =
            (syndrome[vertex >> 3u] &
             (uint8_t)(UINT8_C(1) << (vertex & 7u))) != 0u;
        const bool expected = defect_index < defect_count &&
                              defects[defect_index] == vertex;
        if (!is_virtual(vertex)) {
            assert(actual == expected);
        } else {
            assert(!actual && !expected);
        }
        if (expected) {
            ++defect_index;
        }
    }
    assert(defect_index == defect_count);
    assert(total_weight == minimum_weight);
    for (index = edge_count; index < MICROBLOSSOM_MAX_CORRECTION_EDGES;
         ++index) {
        assert(edges[index] == 0u);
    }
}

static void decode_semantic_case(const char *name, const uint16_t *defects,
                                 uint16_t defect_count,
                                 uint32_t minimum_weight,
                                 uint16_t expected_operations) {
    uint16_t edge_count = UINT16_MAX;
    uint16_t operations = UINT16_MAX;
    uint16_t status;

    reset_mmio();
    build_request_defects(defects, defect_count);
    fill_edges(UINT16_MAX);
    status = microblossom_service_decode(
        (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
        MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count, &operations);
    assert(status == MICROBLOSSOM_DECODE_OK);
    assert_success_trace(operations, expected_operations);
    assert_semantic_correction(defects, defect_count, edge_count,
                               minimum_weight);
    printf("MICROBLOSSOM_R5_PRODUCTION_TRACE graph=%s case=%s operations=%u reads=%u writes=%u correction_edges=%u weight=%u\n",
           MICROBLOSSOM_GRAPH_ID, name, (unsigned)operations, reads, writes,
           (unsigned)edge_count, (unsigned)minimum_weight);
    fflush(stdout);
}

static void assert_sent_semantic_correction(const uint16_t *defects,
                                            uint16_t defect_count,
                                            uint32_t minimum_weight) {
    uint16_t index;
    const uint16_t edge_count =
        get16(sent_packet + QSHELL_HEADER_BYTES + 40u);
    assert(get16(sent_packet + QSHELL_HEADER_BYTES + 42u) ==
           production_singleton_operations);
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        edges[index] = get16(sent_packet + QSHELL_HEADER_BYTES + 44u + 2u * index);
    }
    assert_semantic_correction(defects, defect_count, edge_count,
                               minimum_weight);
}
#endif

static unsigned expected_singleton_mmio_calls(void) {
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    return production_singleton_operations;
#else
    return 10u;
#endif
}

static void test_provider_generation_and_metadata_bounds(void) {
    struct cyt_provider_identity identity = {
        .protocol_version = 1u,
        .stream_abi = 1u,
        .mmio_abi = 1u,
        .receive_depth = 4u,
        .transmit_depth = 4u,
        .max_packet_beats = CYT_PROVIDER_MAX_PACKET_BEATS,
        .data_words_per_beat = 16u,
        .endpoint_generation = 7u,
    };
    struct cyt_provider_packet_metadata input = {0};
    struct cyt_provider_packet_metadata output = {0};
    struct cyt_provider_status status = {
        .endpoint_generation = 7u,
        .binding_generation = 11u,
        .available = true,
        .healthy = true,
        .selected = true,
        .generation_acknowledged = true,
    };
    size_t beat;

    assert(microblossom_service_provider_compatible(&identity));
    identity.max_packet_beats = MICROBLOSSOM_MAX_PACKET_BEATS - 1u;
    assert(!microblossom_service_provider_compatible(&identity));
    identity.max_packet_beats = CYT_PROVIDER_MAX_PACKET_BEATS;
    identity.endpoint_generation = 0u;
    assert(!microblossom_service_provider_compatible(&identity));

    assert(microblossom_service_generation_current(&status, 11u, 7u));
    status.binding_generation = 12u;
    assert(!microblossom_service_generation_current(&status, 11u, 7u));
    status.binding_generation = 11u;
    status.endpoint_generation = 8u;
    assert(!microblossom_service_generation_current(&status, 11u, 7u));
    status.endpoint_generation = 7u;
    status.generation_acknowledged = false;
    assert(!microblossom_service_generation_current(&status, 11u, 7u));

    input.beat_count = MICROBLOSSOM_REQUEST_BEATS;
    for (beat = 0u; beat < input.beat_count; ++beat) {
        input.beat_id[beat] = 17u;
    }
    assert(microblossom_service_prepare_response_metadata(&input, &output));
    assert(output.beat_count == MICROBLOSSOM_RESPONSE_BEATS);
    for (beat = 0u; beat < output.beat_count; ++beat) {
        assert(output.beat_id[beat] == 17u);
    }
    if (input.beat_count > 1u) {
        input.beat_id[input.beat_count - 1u] = 18u;
        assert(!microblossom_service_prepare_response_metadata(&input, &output));
        input.beat_id[input.beat_count - 1u] = 17u;
    }
    --input.beat_count;
    assert(!microblossom_service_prepare_response_metadata(&input, &output));
    assert(!microblossom_service_prepare_response_metadata((const void *)0,
                                                            &output));
    assert(output.beat_count == 0u);
    for (beat = 0u; beat < CYT_PROVIDER_MAX_PACKET_BEATS; ++beat) {
        assert(output.beat_id[beat] == 0u);
    }
}

static void test_decode_boundaries(void) {
    uint16_t edge_count = 0u;
    uint16_t operations = 0u;
#if !defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    uint16_t status;
#endif

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    {
        static const uint16_t singleton_smoke[] = {0u};
        static const uint16_t direct_pair[] = {0u, 3u};
        decode_semantic_case("empty", (const void *)0, 0u, 0u, 14u);
        decode_semantic_case("singleton-smoke", singleton_smoke, 1u, 12u,
                             20u);
        production_singleton_operations = 20u;
        decode_semantic_case("direct-pair", direct_pair, 2u, 14u, 22u);
        if (MICROBLOSSOM_GRAPH_VERTEX_COUNT == 19u) {
            static const uint16_t singleton_other[] = {18u};
            static const uint16_t four_defects[] = {0u, 7u, 14u, 18u};
            static const uint16_t blossom_case[] = {0u, 3u, 4u, 13u};
            static const uint16_t tied_pair[] = {3u, 6u};
            decode_semantic_case("singleton-other", singleton_other, 1u, 12u,
                                 20u);
            decode_semantic_case("four-defect", four_defects, 4u, 36u, 45u);
            decode_semantic_case("blossom", blossom_case, 4u, 28u, 41u);
            decode_semantic_case("equal-weight-tie", tied_pair, 2u, 26u, 27u);
        } else {
            static const uint16_t singleton_other[] = {432u};
            static const uint16_t four_defects[] = {0u, 147u, 294u, 432u};
            static const uint16_t tied_pair[] = {0u, 6u};
            assert(MICROBLOSSOM_GRAPH_VERTEX_COUNT == 433u);
            decode_semantic_case("singleton-other", singleton_other, 1u, 12u,
                                 20u);
            decode_semantic_case("four-defect", four_defects, 4u, 48u, 38u);
            decode_semantic_case("equal-weight-tie", tied_pair, 2u, 52u, 27u);
        }
    }
#else
    reset_mmio();
    build_request(0u);
    status = microblossom_service_decode(
        (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
        MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count, &operations);
    assert(status == MICROBLOSSOM_DECODE_OK);
    assert(edge_count == 0u);
    assert(operations == 5u && reads == 2u && writes == 3u);

    reset_mmio();
    build_request(1u);
    status = microblossom_service_decode(
        (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
        MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count, &operations);
    assert(status == MICROBLOSSOM_DECODE_OK);
    assert(edge_count == 1u && edges[0] == MICROBLOSSOM_SMOKE_CORRECTION_EDGE);
    assert(operations == 10u && reads == 4u && writes == 6u);

    reset_mmio();
    build_request(1u);
    put16(packet + QSHELL_HEADER_BYTES + 40u, nonvirtual_vertex(1u));
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    status = microblossom_service_decode(
        (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
        MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count, &operations);
    assert(status == MICROBLOSSOM_DECODE_UNSUPPORTED_SYNDROME);
    assert_failure_cleared(edge_count);
    assert(operations == 0u && reads == 0u && writes == 0u);

    reset_mmio();
    build_request(2u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    status = microblossom_service_decode(
        (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
        MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count, &operations);
    assert(status == MICROBLOSSOM_DECODE_UNSUPPORTED_SYNDROME);
    assert_failure_cleared(edge_count);
    assert(operations == 0u && reads == 0u && writes == 0u);
#endif

    build_request((uint16_t)(MICROBLOSSOM_MAX_DEFECTS + 1u));
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 2u);
    assert_failure_cleared(edge_count);

    build_request(1u);
    put16(packet + QSHELL_HEADER_BYTES + 42u, UINT16_C(1));
    reset_mmio();
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 2u);
    assert_failure_cleared(edge_count);
    assert(reads == 0u && writes == 0u);

    build_request(1u);
    put16(packet + QSHELL_HEADER_BYTES + 40u,
          MICROBLOSSOM_FIRST_VIRTUAL_VERTEX);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 2u);
    assert_failure_cleared(edge_count);
    assert(reads == 0u && writes == 0u);

    build_request(1u);
    packet[QSHELL_HEADER_BYTES + 8u] ^= UINT8_C(1);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 1u);
    assert_failure_cleared(edge_count);
    assert(reads == 0u && writes == 0u);

    build_request(1u);
    put32(packet + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID, 0u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 1u);
    assert_failure_cleared(edge_count);
    assert(reads == 0u && writes == 0u);

    build_request(1u);
    put32(packet + QSHELL_OFFSET_ROUTE_VERSION, 0u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 1u);
    assert_failure_cleared(edge_count);
    assert(reads == 0u && writes == 0u);

    reset_mmio();
    build_request(1u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    next_mmio_result = CYT_PROVIDER_STALE;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 3u);
    assert_failure_cleared(edge_count);
    assert(operations == 1u);

    reset_mmio();
    build_request(1u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    fail_mmio_call = 10u;
    next_mmio_result = CYT_PROVIDER_BUS_ERROR;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == 3u);
    assert_failure_cleared(edge_count);
    assert(operations == 10u && mmio_calls == 10u);
#if !defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    assert(reads == 4u && writes == 6u);
#endif
}

static void test_decode_failure_scrubs_every_mmio_exit(void) {
    unsigned failure_call;
    uint16_t edge_count;
    uint16_t operations;

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    {
        static const uint16_t d3_fault_defects[] = {0u, 7u, 14u, 18u};
        static const uint16_t d9_fault_defects[] = {0u, 147u, 294u, 432u};
        const uint16_t *fault_defects =
            MICROBLOSSOM_GRAPH_VERTEX_COUNT == 19u ? d3_fault_defects
                                                   : d9_fault_defects;
        const unsigned successful_operations =
            MICROBLOSSOM_GRAPH_VERTEX_COUNT == 19u ? 45u : 38u;
        assert(production_singleton_operations == 20u);
        for (failure_call = 1u; failure_call <= successful_operations;
             ++failure_call) {
            reset_mmio();
            build_request_defects(fault_defects, 4u);
            fill_edges(UINT16_MAX);
            edge_count = UINT16_MAX;
            operations = UINT16_MAX;
            fail_mmio_call = failure_call;
            next_mmio_result = CYT_PROVIDER_BUS_ERROR;
            assert(microblossom_service_decode(
                       (cyt_provider *)1, packet,
                       MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
                       MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
                       &operations) ==
                   MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
            assert_failure_cleared(edge_count);
            assert(operations == failure_call);
            assert(mmio_calls == failure_call);
        }
    }

    reset_mmio();
    build_request(1u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    assert(microblossom_rust_software_accelerator_set_stuck_growth(
               software_accelerator, 1u) == 0u);
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE);
    assert_failure_cleared(edge_count);
    assert(operations == 4096u && mmio_calls == 4096u);

    {
        static const uint16_t recovered[] = {0u};
        decode_semantic_case("post-fault-recovery", recovered, 1u, 12u,
                             production_singleton_operations);
    }
#else
    for (failure_call = 1u; failure_call <= 10u; ++failure_call) {
        reset_mmio();
        build_request(1u);
        fill_edges(UINT16_MAX);
        edge_count = UINT16_MAX;
        operations = UINT16_MAX;
        fail_mmio_call = failure_call;
        next_mmio_result = CYT_PROVIDER_BUS_ERROR;
        assert(microblossom_service_decode(
                   (cyt_provider *)1, packet,
                   MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
                   MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
                   &operations) != MICROBLOSSOM_DECODE_OK);
        assert_failure_cleared(edge_count);
        assert(operations == failure_call);
    }

    reset_mmio();
    build_request(1u);
    fill_edges(UINT16_MAX);
    edge_count = UINT16_MAX;
    accelerator_complete = false;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE);
    assert_failure_cleared(edge_count);
#endif
}

#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
static void test_decode_rejects_hardware_identity_faults(void) {
    uint16_t edge_count;
    uint16_t operations;
    uint16_t fault;

    for (fault = 1u; fault <= 5u; ++fault) {
        reset_mmio();
        build_request(1u);
        fill_edges(UINT16_MAX);
        edge_count = UINT16_MAX;
        operations = UINT16_MAX;
        assert(microblossom_rust_software_accelerator_set_identity_fault(
                   software_accelerator, fault) == 0u);
        assert(microblossom_service_decode(
                   (cyt_provider *)1, packet,
                   MICROBLOSSOM_REQUEST_PACKET_BYTES, edges,
                   MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
                   &operations) == MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
        assert_failure_cleared(edge_count);
        assert(operations >= 1u && operations <= 2u);
        assert(mmio_calls == operations);
    }
}

static void test_decode_rejects_reentrant_workspace_use(void) {
    static const uint16_t singleton[] = {0u};
    uint16_t edge_count = UINT16_MAX;
    uint16_t operations = UINT16_MAX;
    uint16_t index;

    reset_mmio();
    build_request_defects(singleton, 1u);
    fill_edges(UINT16_MAX);
    reenter_mmio_call = 1u;
    assert(microblossom_service_decode(
               (cyt_provider *)1, packet, MICROBLOSSOM_REQUEST_PACKET_BYTES,
               edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, &edge_count,
               &operations) == MICROBLOSSOM_DECODE_OK);
    assert(reentered);
    assert(reentrant_status == MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
    assert(reentrant_edge_count == 0u && reentrant_operations == 0u);
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        assert(reentrant_edges[index] == 0u);
    }
    assert_success_trace(operations, production_singleton_operations);
    assert_semantic_correction(singleton, 1u, edge_count, 12u);
}
#endif

static void test_response_capacity_and_identity(void) {
    size_t index;
    size_t length;

    build_request(1u);
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        edges[index] = (uint16_t)index;
    }
    length = microblossom_service_make_response(
        packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, response, sizeof(response), 0u,
        edges, MICROBLOSSOM_MAX_CORRECTION_EDGES, UINT16_C(123));
    assert(length == MICROBLOSSOM_RESPONSE_PACKET_BYTES);
    assert(response[QSHELL_OFFSET_RECORD_CLASS] == QSHELL_CLASS_CORRECTION);
    assert(get32(response + QSHELL_OFFSET_PAYLOAD_BYTES) ==
           MICROBLOSSOM_RESPONSE_PAYLOAD_BYTES);
    assert(get32(response + QSHELL_OFFSET_SCHEMA_ID) ==
           QSHELL_SCHEMA_MICROBLOSSOM_DECODE_RESULT);
    assert(get32(response + QSHELL_OFFSET_SOURCE_ENDPOINT_ID) == 9u);
    assert(get32(response + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID) == 7u);
    assert(get32(response + QSHELL_OFFSET_ROUTE_CAPABILITY_ID) == 11u);
    assert(get32(response + QSHELL_OFFSET_ROUTE_VERSION) == 13u);
    assert(memcmp(response + QSHELL_HEADER_BYTES + 8u,
                  microblossom_graph_identity, 32u) == 0);
    assert(get16(response + QSHELL_HEADER_BYTES + 40u) ==
           MICROBLOSSOM_MAX_CORRECTION_EDGES);
    assert(get16(response + QSHELL_HEADER_BYTES + 42u) == 123u);
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        assert(get16(response + QSHELL_HEADER_BYTES + 44u + 2u * index) ==
               edges[index]);
    }

    edges[MICROBLOSSOM_MAX_CORRECTION_EDGES - 1u] =
        MICROBLOSSOM_GRAPH_EDGE_COUNT;
    assert(microblossom_service_make_response(
               packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, response,
               sizeof(response), 0u, edges,
               MICROBLOSSOM_MAX_CORRECTION_EDGES, 0u) == 0u);

    edges[0] = 1u;
    edges[1] = 1u;
    assert(microblossom_service_make_response(
               packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, response,
               sizeof(response), 0u, edges, 2u, 0u) == 0u);
    for (index = 0u; index < MICROBLOSSOM_RESPONSE_PACKET_BYTES; ++index) {
        assert(response[index] == 0u);
    }
    edges[0] = 2u;
    edges[1] = 1u;
    assert(microblossom_service_make_response(
               packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, response,
               sizeof(response), 0u, edges, 2u, 0u) == 0u);

    build_request(1u);
    edges[0] = MICROBLOSSOM_SMOKE_CORRECTION_EDGE;
    assert(microblossom_service_make_response(
               packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, response,
               sizeof(response), 0u, edges, 0u, 0u) == 0u);
    length = microblossom_service_make_response(
        packet, MICROBLOSSOM_REQUEST_PACKET_BYTES, response, sizeof(response), 5u,
        edges, 1u, 0u);
    assert(length == MICROBLOSSOM_RESPONSE_PACKET_BYTES);
    assert(get16(response + QSHELL_HEADER_BYTES + 6u) == 5u);
    assert(get16(response + QSHELL_HEADER_BYTES + 40u) == 0u);
    for (index = 0u; index < MICROBLOSSOM_MAX_CORRECTION_EDGES; ++index) {
        assert(get16(response + QSHELL_HEADER_BYTES + 44u + 2u * index) == 0u);
    }
}

static void initialize_bound_runtime(
    struct microblossom_service_runtime *runtime) {
    reset_provider_mock();
    microblossom_service_runtime_init(runtime);
    assert(runtime->connection == MICROBLOSSOM_SERVICE_CLOSED);
    assert(microblossom_service_step(runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime->connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(microblossom_service_step(runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime->connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(runtime->binding_generation == 11u);
    assert(mock.open_calls == 1u && mock.refresh_calls == 1u);
    assert(mock.idle_calls == 1u);
    mock.status_calls = 0u;
    mock.receive_calls = 0u;
}

static void test_runtime_receive_storage_boundary(void) {
    struct microblossom_service_runtime runtime;
    const size_t request_storage_bytes =
        MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES;
    size_t beat;

    initialize_bound_runtime(&runtime);
    reset_mmio();
    build_request(1u);
    mock.receive_result = CYT_PROVIDER_OK;
    mock.receive_length = request_storage_bytes + 1u;
    mock.receive_metadata.beat_count =
        (uint16_t)((mock.receive_length + QSHELL_BEAT_BYTES - 1u) /
                   QSHELL_BEAT_BYTES);
    for (beat = 0u; beat < mock.receive_metadata.beat_count; ++beat) {
        mock.receive_metadata.beat_id[beat] = 17u;
    }
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(mock.receive_calls == 1u);
    assert(mock.receive_capacity == MICROBLOSSOM_PACKET_STORAGE_BYTES);
    assert(mock.busy_calls == 0u && mock.send_calls == 0u && mmio_calls == 0u);

    build_request(1u);
    mock.receive_length = MICROBLOSSOM_REQUEST_PACKET_BYTES;
    mock.receive_metadata.beat_count = MICROBLOSSOM_REQUEST_BEATS;
    for (beat = 0u; beat < mock.receive_metadata.beat_count; ++beat) {
        mock.receive_metadata.beat_id[beat] = 17u;
    }
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_RESPONSE_SENT);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(mock.receive_calls == 2u && mock.send_calls == 1u);
    assert(mock.sent_decode_status == MICROBLOSSOM_DECODE_OK);
}

static void test_runtime_lifecycle_transitions(void) {
    struct microblossom_service_runtime runtime;

    reset_provider_mock();
    microblossom_service_runtime_init(&runtime);
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(mock.open_calls == 1u);

    mock.refresh_result = CYT_PROVIDER_UNBOUND;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_WAITING);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(mock.open_calls == 1u && mock.refresh_calls == 1u);

    mock.refresh_result = CYT_PROVIDER_OK;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(runtime.binding_generation == 11u);

    mock.status.binding_generation = 12u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(mock.open_calls == 1u);
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(runtime.binding_generation == 12u);
    assert(mock.open_calls == 1u);

    mock.status.endpoint_generation = 8u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    mock.identity.endpoint_generation = 8u;
    mock.status.binding_generation = 20u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(runtime.identity.endpoint_generation == 8u);
    assert(mock.open_calls == 2u);

    mock.refresh_result = CYT_PROVIDER_STALE;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    mock.refresh_result = CYT_PROVIDER_OK;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(mock.open_calls == 3u);
}

static void test_runtime_publication_failures(void) {
    struct microblossom_service_runtime runtime;

    initialize_bound_runtime(&runtime);
    reset_mmio();
    build_request(1u);
    mock.receive_result = CYT_PROVIDER_OK;
    mock.busy_result = CYT_PROVIDER_BUS_ERROR;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    assert(mock.busy_calls == 1u && mock.send_calls == 0u);
    assert(mmio_calls == 0u);

    initialize_bound_runtime(&runtime);
    reset_mmio();
    build_request(1u);
    mock.receive_result = CYT_PROVIDER_OK;
    mock.idle_result = CYT_PROVIDER_BUS_ERROR;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    assert(mock.busy_calls == 1u && mock.send_calls == 0u);
    assert(mmio_calls == expected_singleton_mmio_calls());

    initialize_bound_runtime(&runtime);
    mock.status.quiesce_requested = true;
    mock.idle_result = CYT_PROVIDER_BUS_ERROR;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    assert(mock.receive_calls == 0u && mock.quiesce_calls == 0u);

    initialize_bound_runtime(&runtime);
    mock.status.quiesce_requested = true;
    mock.quiesce_result = CYT_PROVIDER_BUS_ERROR;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    assert(mock.receive_calls == 0u && mock.quiesce_calls == 1u);
}

static void test_runtime_generation_recheck(void) {
    struct microblossom_service_runtime runtime;

    initialize_bound_runtime(&runtime);
    reset_mmio();
    build_request(1u);
    mock.receive_result = CYT_PROVIDER_OK;
    mock.changed_status = mock.status;
    mock.changed_status.binding_generation = 12u;
    mock.change_status_read = 2u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(mock.busy_calls == 1u && mock.send_calls == 0u);
    assert(mmio_calls == expected_singleton_mmio_calls());
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(mock.open_calls == 1u);

    mock.change_status_read = 0u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(runtime.binding_generation == 12u);
    assert(mock.open_calls == 1u);

    mock.status_calls = 0u;
    mock.receive_calls = 0u;
    mock.receive_result = CYT_PROVIDER_OK;
    mock.changed_status = mock.status;
    mock.changed_status.endpoint_generation = 8u;
    mock.change_status_read = 2u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_JOB_FAILED);
    assert(mock.send_calls == 0u);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_CLOSED);
    mock.identity.endpoint_generation = 8u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_OPEN_UNBOUND);
    assert(mock.open_calls == 2u);
    mock.change_status_read = 0u;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_CONNECTION_CHANGED);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(runtime.binding_generation == mock.status.binding_generation);

    reset_mmio();
    build_request(1u);
    mock.receive_result = CYT_PROVIDER_OK;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_RESPONSE_SENT);
    assert(mock.send_calls == 1u);
    assert(mock.sent_decode_status == MICROBLOSSOM_DECODE_OK);
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    {
        static const uint16_t singleton[] = {0u};
        assert_sent_semantic_correction(singleton, 1u, 12u);
    }
#else
    assert(mock.sent_edge_count == 1u);
#endif
}

static void test_runtime_production_and_error_responses(void) {
    struct microblossom_service_runtime runtime;

    initialize_bound_runtime(&runtime);
    reset_mmio();
    build_request(1u);
    mock.receive_result = CYT_PROVIDER_OK;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_RESPONSE_SENT);
    assert(runtime.connection == MICROBLOSSOM_SERVICE_BOUND);
    assert(mock.sent_length == MICROBLOSSOM_RESPONSE_PACKET_BYTES);
    assert(mock.sent_decode_status == MICROBLOSSOM_DECODE_OK);
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    {
        static const uint16_t singleton[] = {0u};
        assert_sent_semantic_correction(singleton, 1u, 12u);
    }
#else
    assert(mock.sent_edge_count == 1u);
#endif

    reset_mmio();
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    {
        const uint16_t singleton =
            MICROBLOSSOM_GRAPH_VERTEX_COUNT == 19u ? 18u : 432u;
        build_request_defects(&singleton, 1u);
        assert(microblossom_service_step(&runtime, &test_firmware) ==
               MICROBLOSSOM_SERVICE_RESPONSE_SENT);
        assert(mock.sent_decode_status == MICROBLOSSOM_DECODE_OK);
        assert_sent_semantic_correction(&singleton, 1u, 12u);
    }
#else
    build_request(1u);
    put16(packet + QSHELL_HEADER_BYTES + 40u, nonvirtual_vertex(1u));
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_RESPONSE_SENT);
    assert(mock.sent_decode_status ==
           MICROBLOSSOM_DECODE_UNSUPPORTED_SYNDROME);
    assert(mock.sent_edge_count == 0u);
    assert(mmio_calls == 0u);
#endif

    reset_mmio();
    build_request(1u);
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    fail_mmio_call = production_singleton_operations - 3u;
#else
    fail_mmio_call = 10u;
#endif
    next_mmio_result = CYT_PROVIDER_BUS_ERROR;
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_RESPONSE_SENT);
    assert(mock.sent_decode_status ==
           MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
    assert(mock.sent_edge_count == 0u);
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    assert(mmio_calls == production_singleton_operations - 3u);
    assert(mmio_trace[mmio_trace_count - 1u].write);
    assert(mmio_trace[mmio_trace_count - 1u].offset == UINT16_C(0x010));
    assert(mmio_trace[mmio_trace_count - 1u].value == UINT32_C(0x24));
#endif

    reset_mmio();
    build_request(0u);
    assert(microblossom_service_step(&runtime, &test_firmware) ==
           MICROBLOSSOM_SERVICE_RESPONSE_SENT);
    assert(mock.sent_decode_status == MICROBLOSSOM_DECODE_OK);
    assert(mock.sent_edge_count == 0u);
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    assert(get16(sent_packet + QSHELL_HEADER_BYTES + 42u) == 14u);
#endif
}

int main(void) {
    assert(MICROBLOSSOM_REQUEST_PACKET_BYTES <=
           MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES);
    assert(MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES <=
           MICROBLOSSOM_PACKET_STORAGE_BYTES);
    assert(MICROBLOSSOM_RESPONSE_PACKET_BYTES <=
           MICROBLOSSOM_PACKET_STORAGE_BYTES);
    assert(MICROBLOSSOM_VIRTUAL_VERTEX_BITMAP_BYTES ==
           (MICROBLOSSOM_GRAPH_VERTEX_COUNT + 7u) / 8u);
    assert(MICROBLOSSOM_SMOKE_DEFECT_VERTEX == nonvirtual_vertex(0u));
    test_provider_generation_and_metadata_bounds();
    test_decode_boundaries();
    test_decode_failure_scrubs_every_mmio_exit();
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    test_decode_rejects_hardware_identity_faults();
    test_decode_rejects_reentrant_workspace_use();
#endif
    test_response_capacity_and_identity();
    test_runtime_receive_storage_boundary();
    test_runtime_lifecycle_transitions();
    test_runtime_publication_failures();
    test_runtime_generation_recheck();
    test_runtime_production_and_error_responses();
#if defined(MICROBLOSSOM_RUST_DECODER_LINKED)
    microblossom_rust_software_accelerator_destroy(software_accelerator);
    software_accelerator = (void *)0;
#endif
    printf("MICROBLOSSOM_R5_SERVICE_PASS graph=%s request_beats=%u response_beats=%u storage_bytes=%u request_storage_bytes=%u response_storage_bytes=%u\n",
           MICROBLOSSOM_GRAPH_ID, (unsigned)MICROBLOSSOM_REQUEST_BEATS,
           (unsigned)MICROBLOSSOM_RESPONSE_BEATS,
           (unsigned)MICROBLOSSOM_PACKET_STORAGE_BYTES,
           (unsigned)(MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES),
           (unsigned)MICROBLOSSOM_PACKET_STORAGE_BYTES);
    return 0;
}
