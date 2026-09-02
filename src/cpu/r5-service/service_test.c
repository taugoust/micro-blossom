#include "provider.h"
#include "qshell_abi_generated.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

uint16_t microblossom_service_decode(cyt_provider *,const uint8_t *,size_t,uint16_t *,uint16_t *,uint16_t *);
void microblossom_service_make_response(const uint8_t *,uint8_t *,uint16_t,const uint16_t *,uint16_t,uint16_t);

static unsigned reads,writes;
enum cyt_provider_result cyt_provider_app_read64(cyt_provider *p,uint16_t o,uint64_t *v,struct cyt_provider_wait *w){
 (void)p;(void)w;++reads;if(o==0)*v=((uint64_t)1<<32)|0x240123c0u;else if(o==0x30)*v=(uint64_t)1<<48;else *v=0;return CYT_PROVIDER_OK;}
enum cyt_provider_result cyt_provider_app_write64(cyt_provider *p,uint16_t o,uint64_t v,uint8_t s,struct cyt_provider_wait *w){(void)p;(void)o;(void)v;(void)s;(void)w;++writes;return CYT_PROVIDER_OK;}
void cyt_provider_install_r5_transport(void){}
enum cyt_provider_result cyt_provider_open(const struct cyt_provider_firmware_identity*a,cyt_provider**b,struct cyt_provider_identity*c){(void)a;(void)b;(void)c;return CYT_PROVIDER_NOT_PRESENT;}
enum cyt_provider_result cyt_provider_refresh_binding(cyt_provider*p){(void)p;return CYT_PROVIDER_UNBOUND;}
enum cyt_provider_result cyt_provider_read_status(cyt_provider*p,struct cyt_provider_status*s){(void)p;(void)s;return CYT_PROVIDER_UNBOUND;}
enum cyt_provider_result cyt_provider_receive(cyt_provider*p,void*b,size_t c,size_t*l,struct cyt_provider_packet_metadata*m,struct cyt_provider_wait*w){(void)p;(void)b;(void)c;(void)l;(void)m;(void)w;return CYT_PROVIDER_UNBOUND;}
enum cyt_provider_result cyt_provider_send(cyt_provider*p,const void*b,size_t l,const struct cyt_provider_packet_metadata*m,struct cyt_provider_wait*w){(void)p;(void)b;(void)l;(void)m;(void)w;return CYT_PROVIDER_UNBOUND;}
enum cyt_provider_result cyt_provider_set_idle(cyt_provider*p,bool i){(void)p;(void)i;return CYT_PROVIDER_OK;}
enum cyt_provider_result cyt_provider_ack_quiesce(cyt_provider*p){(void)p;return CYT_PROVIDER_OK;}
enum cyt_provider_result cyt_provider_report_fault(cyt_provider*p,uint16_t c,uint16_t d){(void)p;(void)c;(void)d;return CYT_PROVIDER_OK;}

static void put16(uint8_t*p,uint16_t v){p[0]=v;p[1]=v>>8;}
static void put32(uint8_t*p,uint32_t v){p[0]=v;p[1]=v>>8;p[2]=v>>16;p[3]=v>>24;}
static uint32_t get32(const uint8_t*p){return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
int main(void){
 static const uint8_t graph[32]={0x4b,0x07,0x8d,0x3b,0x6c,0x6d,0xb2,0x4e,0xa9,0x72,0x64,0x14,0x56,0x9a,0x97,0xb3,0x89,0x9b,0xe4,0xe5,0x32,0xbe,0x1c,0x0e,0xbd,0x84,0xb5,0xfa,0x87,0x53,0x16,0xc5};
 uint8_t packet[QSHELL_HEADER_BYTES+48u]={0},response[QSHELL_HEADER_BYTES+48u]={0};uint16_t edges[2]={0},count=0,ops=0;
 put32(packet+QSHELL_OFFSET_MAGIC,QSHELL_MAGIC);packet[QSHELL_OFFSET_ABI_VERSION]=QSHELL_ABI_VERSION;packet[QSHELL_OFFSET_RECORD_CLASS]=QSHELL_CLASS_SYNDROME;put16(packet+QSHELL_OFFSET_FLAGS,QSHELL_FLAG_END_OF_ROUND);put16(packet+QSHELL_OFFSET_HEADER_BYTES,QSHELL_HEADER_BYTES);put32(packet+QSHELL_OFFSET_PAYLOAD_BYTES,48u);put32(packet+QSHELL_OFFSET_SCHEMA_ID,QSHELL_SCHEMA_MICROBLOSSOM_DECODE_REQUEST);put32(packet+QSHELL_OFFSET_SOURCE_ENDPOINT_ID,7);put32(packet+QSHELL_OFFSET_DESTINATION_ENDPOINT_ID,9);put32(packet+QSHELL_HEADER_BYTES,0x314a424d);put16(packet+QSHELL_HEADER_BYTES+4u,1);put16(packet+QSHELL_HEADER_BYTES+6u,1);memcpy(packet+QSHELL_HEADER_BYTES+8u,graph,32);put16(packet+QSHELL_HEADER_BYTES+40u,0);
 assert(microblossom_service_decode((cyt_provider*)1,packet,sizeof(packet),edges,&count,&ops)==0);assert(count==1&&edges[0]==2);assert(reads==4&&writes==6);
 microblossom_service_make_response(packet,response,0,edges,count,ops);
 assert(response[QSHELL_OFFSET_RECORD_CLASS]==QSHELL_CLASS_CORRECTION&&get32(response+QSHELL_OFFSET_SCHEMA_ID)==QSHELL_SCHEMA_MICROBLOSSOM_DECODE_RESULT&&get32(response+QSHELL_OFFSET_SOURCE_ENDPOINT_ID)==9&&get32(response+QSHELL_OFFSET_DESTINATION_ENDPOINT_ID)==7);
 assert(response[QSHELL_HEADER_BYTES]=='M'&&response[QSHELL_HEADER_BYTES+1u]=='B'&&response[QSHELL_HEADER_BYTES+2u]=='R'&&response[QSHELL_HEADER_BYTES+3u]=='1');
 assert(response[QSHELL_HEADER_BYTES+40u]==1&&response[QSHELL_HEADER_BYTES+42u]==10&&response[QSHELL_HEADER_BYTES+44u]==2);
 put32(packet+QSHELL_OFFSET_SCHEMA_ID,QSHELL_SCHEMA_MICROBLOSSOM_DECODE_RESULT);assert(microblossom_service_decode((cyt_provider*)1,packet,sizeof(packet),edges,&count,&ops)==1);put32(packet+QSHELL_OFFSET_SCHEMA_ID,QSHELL_SCHEMA_MICROBLOSSOM_DECODE_REQUEST);
 puts("MICROBLOSSOM_R5_SERVICE_PASS");return 0;
}
