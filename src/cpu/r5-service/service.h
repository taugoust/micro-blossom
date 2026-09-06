#ifndef MICROBLOSSOM_R5_SERVICE_H
#define MICROBLOSSOM_R5_SERVICE_H

#include "microblossom_graph_contract.h"
#include "provider.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum microblossom_decode_status {
    MICROBLOSSOM_DECODE_OK = 0,
    MICROBLOSSOM_DECODE_MALFORMED_RECORD = 1,
    MICROBLOSSOM_DECODE_INVALID_SYNDROME = 2,
    MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE = 3,
    MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE = 4,
    MICROBLOSSOM_DECODE_UNSUPPORTED_SYNDROME = 5,
};

enum microblossom_service_connection_state {
    MICROBLOSSOM_SERVICE_CLOSED = 0,
    MICROBLOSSOM_SERVICE_OPEN_UNBOUND,
    MICROBLOSSOM_SERVICE_BOUND,
};

enum microblossom_service_step_result {
    MICROBLOSSOM_SERVICE_WAITING = 0,
    MICROBLOSSOM_SERVICE_CONNECTION_CHANGED,
    MICROBLOSSOM_SERVICE_RESPONSE_SENT,
    MICROBLOSSOM_SERVICE_JOB_FAILED,
};

struct microblossom_service_runtime {
    cyt_provider *provider;
    struct cyt_provider_identity identity;
    enum microblossom_service_connection_state connection;
    uint32_t binding_generation;
};

void microblossom_service_runtime_init(
    struct microblossom_service_runtime *runtime);

enum microblossom_service_step_result microblossom_service_step(
    struct microblossom_service_runtime *runtime,
    const struct cyt_provider_firmware_identity *firmware);

bool microblossom_service_provider_compatible(
    const struct cyt_provider_identity *identity);

bool microblossom_service_prepare_response_metadata(
    const struct cyt_provider_packet_metadata *request_metadata,
    struct cyt_provider_packet_metadata *response_metadata);

bool microblossom_service_generation_current(
    const struct cyt_provider_status *status,
    uint32_t binding_generation,
    uint32_t endpoint_generation);

uint16_t microblossom_service_decode(
    cyt_provider *provider,
    const uint8_t *packet,
    size_t length,
    uint16_t *edges,
    size_t edge_capacity,
    uint16_t *edge_count,
    uint16_t *operations);

size_t microblossom_service_make_response(
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity,
    uint16_t status,
    const uint16_t *edges,
    uint16_t edge_count,
    uint16_t operations);

#endif
