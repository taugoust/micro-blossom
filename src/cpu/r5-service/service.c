#include "provider.h"
#include "provider_platform.h"
#include "qshell_abi_generated.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define REQUEST_MAGIC UINT32_C(0x314a424d)
#define RESULT_MAGIC UINT32_C(0x3152424d)
#define SERVICE_VERSION UINT16_C(1)
#define DECODE_PAYLOAD_BYTES 48u
#define PACKET_BYTES (QSHELL_HEADER_BYTES + DECODE_PAYLOAD_BYTES)
#define MAX_DEFECTS 4u
#define MAX_EDGES 2u
#define MMIO_POLLS UINT32_C(4096)
#define MMIO_HARDWARE_INFO UINT16_C(0x000)
#define MMIO_INSTRUCTION UINT16_C(0x010)
#define MMIO_CLEAR_GROWN UINT16_C(0x018)
#define MMIO_MAXIMUM_GROWTH UINT16_C(0x020)
#define MMIO_READOUT_LOW UINT16_C(0x028)
#define MMIO_READOUT_HIGH UINT16_C(0x030)
#define ACCELERATOR_VERSION UINT32_C(0x240123c0)
#define INSTRUCTION_RESET UINT32_C(0x24)

#if !defined(CYT_PROVIDER_IDENTITY_WORD_0) || !defined(CYT_PROVIDER_IDENTITY_WORD_1) || \
    !defined(CYT_PROVIDER_IDENTITY_WORD_2) || !defined(CYT_PROVIDER_IDENTITY_WORD_3) || \
    !defined(CYT_PROVIDER_IDENTITY_WORD_4) || !defined(CYT_PROVIDER_IDENTITY_WORD_5) || \
    !defined(CYT_PROVIDER_IDENTITY_WORD_6) || !defined(CYT_PROVIDER_IDENTITY_WORD_7)
#error "The reproducible build must provide the firmware image identity"
#endif

static const uint8_t graph_identity[32] = {
    0x4b,0x07,0x8d,0x3b,0x6c,0x6d,0xb2,0x4e,0xa9,0x72,0x64,0x14,0x56,0x9a,0x97,0xb3,
    0x89,0x9b,0xe4,0xe5,0x32,0xbe,0x1c,0x0e,0xbd,0x84,0xb5,0xfa,0x87,0x53,0x16,0xc5
};
struct service_status { uint32_t words[16]; };
__attribute__((section(".fixture_status"), aligned(64), used))
static struct service_status resident_status;
static uint8_t request[CYT_PROVIDER_MAX_PACKET_BYTES];
static uint8_t response[CYT_PROVIDER_MAX_PACKET_BYTES];
static struct cyt_provider_packet_metadata metadata;

static void record_status(uint32_t phase, uint32_t result, uint32_t detail) {
    size_t index;
    for (index=0u;index<16u;++index) resident_status.words[index]=0u;
    resident_status.words[0]=UINT32_C(0x5352424d);
    resident_status.words[1]=1u;
    resident_status.words[2]=(uint32_t)sizeof(resident_status);
    resident_status.words[3]=phase;
    resident_status.words[4]=result;
    resident_status.words[5]=detail;
    resident_status.words[6]=CYT_PROVIDER_IDENTITY_WORD_0;
    resident_status.words[7]=CYT_PROVIDER_IDENTITY_WORD_1;
    resident_status.words[15]=UINT32_C(0xc05e17ed);
}

static uint16_t load16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8u); }
static uint32_t load32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8u) | ((uint32_t)p[2] << 16u) |
           ((uint32_t)p[3] << 24u);
}
static void store16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8u); }
static void store32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8u); p[2]=(uint8_t)(v>>16u); p[3]=(uint8_t)(v>>24u);
}
static void copy_bytes(uint8_t *d, const uint8_t *s, size_t n) { while (n-- != 0u) *d++=*s++; }
static bool equal_bytes(const uint8_t *a, const uint8_t *b, size_t n) {
    while (n-- != 0u) if (*a++ != *b++) return false;
    return true;
}

static enum cyt_provider_result read64(cyt_provider *provider, uint16_t offset, uint64_t *value) {
    struct cyt_provider_wait wait = {.polls_left = MMIO_POLLS};
    return cyt_provider_app_read64(provider, offset, value, &wait);
}
static enum cyt_provider_result write64(cyt_provider *provider, uint16_t offset,
                                         uint64_t value, uint8_t strobe) {
    struct cyt_provider_wait wait = {.polls_left = MMIO_POLLS};
    return cyt_provider_app_write64(provider, offset, value, strobe, &wait);
}

uint16_t microblossom_service_decode(cyt_provider *provider, const uint8_t *packet, size_t length,
                       uint16_t *edges, uint16_t *edge_count, uint16_t *operations) {
    uint16_t defects[MAX_DEFECTS];
    uint16_t count;
    uint64_t value;
    uint64_t low;
    uint64_t high;
    uint16_t i;
    enum cyt_provider_result result;
    *edge_count = 0u;
    *operations = 0u;
    if (length != PACKET_BYTES ||
        load32(packet + QSHELL_OFFSET_MAGIC) != QSHELL_MAGIC ||
        packet[QSHELL_OFFSET_ABI_VERSION] != QSHELL_ABI_VERSION ||
        packet[QSHELL_OFFSET_RECORD_CLASS] != QSHELL_CLASS_SYNDROME ||
        load16(packet + QSHELL_OFFSET_FLAGS) != QSHELL_FLAG_END_OF_ROUND ||
        load16(packet + QSHELL_OFFSET_HEADER_BYTES) != QSHELL_HEADER_BYTES ||
        load32(packet + QSHELL_OFFSET_PAYLOAD_BYTES) != DECODE_PAYLOAD_BYTES ||
        load32(packet + QSHELL_OFFSET_SCHEMA_ID) != QSHELL_SCHEMA_MICROBLOSSOM_DECODE_REQUEST ||
        load32(packet + QSHELL_HEADER_BYTES) != REQUEST_MAGIC ||
        load16(packet + QSHELL_HEADER_BYTES + 4u) != SERVICE_VERSION ||
        !equal_bytes(packet + QSHELL_HEADER_BYTES + 8u, graph_identity, 32u)) return 1u;
    count = load16(packet + QSHELL_HEADER_BYTES + 6u);
    if (count > MAX_DEFECTS) return 2u;
    for (i=0u;i<count;++i) {
        defects[i]=load16(packet + QSHELL_HEADER_BYTES + 40u + 2u*i);
        if (defects[i] > 1u || (i != 0u && defects[i] <= defects[i-1u])) return 2u;
    }
    result=read64(provider,MMIO_HARDWARE_INFO,&value); ++*operations;
    if (result != CYT_PROVIDER_OK || (uint32_t)value != ACCELERATOR_VERSION || (uint32_t)(value>>32u) != 1u) return 3u;
    result=write64(provider,MMIO_INSTRUCTION,INSTRUCTION_RESET,0xffu); ++*operations;
    if (result != CYT_PROVIDER_OK) return 3u;
    result=read64(provider,MMIO_READOUT_LOW,&low); ++*operations;
    if (result != CYT_PROVIDER_OK) return 3u;
    result=write64(provider,MMIO_CLEAR_GROWN,0u,0x03u); ++*operations;
    if (result != CYT_PROVIDER_OK) return 3u;
    for (i=0u;i<count;++i) {
        uint32_t instruction=((uint32_t)defects[i]<<17u)|((uint32_t)i<<2u)|UINT32_C(2);
        result=write64(provider,MMIO_INSTRUCTION,instruction,0xffu); ++*operations;
        if (result != CYT_PROVIDER_OK) return 3u;
    }
    if (count != 0u) {
        result=write64(provider,MMIO_MAXIMUM_GROWTH,UINT16_MAX,0x03u); ++*operations;
        if (result != CYT_PROVIDER_OK) return 3u;
        result=read64(provider,MMIO_READOUT_LOW,&low); ++*operations;
        if (result != CYT_PROVIDER_OK) return 3u;
        result=read64(provider,MMIO_READOUT_HIGH,&high); ++*operations;
        if (result != CYT_PROVIDER_OK || ((high>>48u)&UINT64_C(0xff)) == 0u) return 4u;
        result=write64(provider,MMIO_CLEAR_GROWN,0u,0x03u); ++*operations;
        if (result != CYT_PROVIDER_OK) return 3u;
    }
    if (count == 1u) { edges[0] = defects[0] == 0u ? 2u : 1u; *edge_count=1u; }
    else if (count == 2u) { edges[0]=0u; *edge_count=1u; }
    result=write64(provider,MMIO_INSTRUCTION,INSTRUCTION_RESET,0xffu); ++*operations;
    return result == CYT_PROVIDER_OK ? 0u : 3u;
}

void microblossom_service_make_response(const uint8_t *input, uint8_t *output,
                          uint16_t status, const uint16_t *edges,
                          uint16_t edge_count, uint16_t operations) {
    size_t i;
    for (i=0u;i<PACKET_BYTES;++i) output[i]=0u;
    copy_bytes(output,input,QSHELL_HEADER_BYTES);
    output[QSHELL_OFFSET_RECORD_CLASS]=QSHELL_CLASS_CORRECTION;
    store32(output + QSHELL_OFFSET_PAYLOAD_BYTES,DECODE_PAYLOAD_BYTES);
    store32(output + QSHELL_OFFSET_SCHEMA_ID,QSHELL_SCHEMA_MICROBLOSSOM_DECODE_RESULT);
    store32(output + QSHELL_OFFSET_SOURCE_ENDPOINT_ID,
            load32(input + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID));
    store32(output + QSHELL_OFFSET_DESTINATION_ENDPOINT_ID,
            load32(input + QSHELL_OFFSET_SOURCE_ENDPOINT_ID));
    store32(output + QSHELL_HEADER_BYTES,RESULT_MAGIC);
    store16(output + QSHELL_HEADER_BYTES + 4u,SERVICE_VERSION);
    store16(output + QSHELL_HEADER_BYTES + 6u,status);
    copy_bytes(output + QSHELL_HEADER_BYTES + 8u,graph_identity,32u);
    store16(output + QSHELL_HEADER_BYTES + 40u,edge_count);
    store16(output + QSHELL_HEADER_BYTES + 42u,operations);
    for (i=0u;i<edge_count && i<MAX_EDGES;++i)
        store16(output + QSHELL_HEADER_BYTES + 44u + 2u*i,edges[i]);
}

void r5_main(void) {
    static const struct cyt_provider_firmware_identity firmware = {
        .runtime_abi=1u, .firmware_abi=1u,
        .image_identity={CYT_PROVIDER_IDENTITY_WORD_0,CYT_PROVIDER_IDENTITY_WORD_1,
         CYT_PROVIDER_IDENTITY_WORD_2,CYT_PROVIDER_IDENTITY_WORD_3,
         CYT_PROVIDER_IDENTITY_WORD_4,CYT_PROVIDER_IDENTITY_WORD_5,
         CYT_PROVIDER_IDENTITY_WORD_6,CYT_PROVIDER_IDENTITY_WORD_7}
    };
    cyt_provider *provider=(void*)0;
    struct cyt_provider_identity identity;
    bool opened=false;
    record_status(1u,0u,0u);
    cyt_provider_install_r5_transport();
    for (;;) {
        enum cyt_provider_result result;
        struct cyt_provider_status status;
        if (!opened) {
            result=cyt_provider_open(&firmware,&provider,&identity);
            if (result != CYT_PROVIDER_OK) continue;
            opened=true;
            record_status(2u,0u,identity.endpoint_generation);
        }
        result=cyt_provider_refresh_binding(provider);
        if (result == CYT_PROVIDER_UNBOUND || result == CYT_PROVIDER_STALE) continue;
        if (result != CYT_PROVIDER_OK) { opened=false; continue; }
        (void)cyt_provider_set_idle(provider,true);
        for (;;) {
            struct cyt_provider_wait wait={.polls_left=0u};
            size_t length=0u;
            uint16_t edges[MAX_EDGES]={0u,0u};
            uint16_t edge_count=0u, operations=0u, decode_status;
            result=cyt_provider_read_status(provider,&status);
            if (result != CYT_PROVIDER_OK || status.aborted || !status.selected) break;
            if (status.quiesce_requested) {
                (void)cyt_provider_set_idle(provider,true);
                (void)cyt_provider_ack_quiesce(provider);
                continue;
            }
            result=cyt_provider_receive(provider,request,sizeof(request),&length,&metadata,&wait);
            if (result == CYT_PROVIDER_WOULD_BLOCK) continue;
            if (result != CYT_PROVIDER_OK) break;
            (void)cyt_provider_set_idle(provider,false);
            decode_status=microblossom_service_decode(provider,request,length,edges,&edge_count,&operations);
            record_status(3u,decode_status,operations);
            microblossom_service_make_response(request,response,decode_status,edges,edge_count,operations);
            wait.polls_left=MMIO_POLLS;
            result=cyt_provider_send(provider,response,PACKET_BYTES,&metadata,&wait);
            (void)cyt_provider_set_idle(provider,true);
            if (result != CYT_PROVIDER_OK) break;
        }
    }
}

__attribute__((noreturn)) void r5_exception_trap(uint32_t exception_class,
                                                 uint32_t fault_address,
                                                 uint32_t syndrome) {
    (void)exception_class; (void)fault_address; (void)syndrome;
#if defined(__arm__)
    for (;;) __asm__ volatile("dsb sy\n\twfi" ::: "memory");
#else
    for (;;) { }
#endif
}
__attribute__((noreturn)) void r5_internal_trap(void) { r5_exception_trap(0u,0u,0u); }
