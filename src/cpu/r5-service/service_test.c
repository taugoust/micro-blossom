#include "provider.h"
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
int main(void){
 static const uint8_t graph[32]={0x4b,0x07,0x8d,0x3b,0x6c,0x6d,0xb2,0x4e,0xa9,0x72,0x64,0x14,0x56,0x9a,0x97,0xb3,0x89,0x9b,0xe4,0xe5,0x32,0xbe,0x1c,0x0e,0xbd,0x84,0xb5,0xfa,0x87,0x53,0x16,0xc5};
 uint8_t packet[96]={0},response[96]={0};uint16_t edges[2]={0},count=0,ops=0;
 put32(packet,0x32485351);packet[4]=2;packet[5]=1;put16(packet+6,1);put16(packet+8,48);put32(packet+12,48);put32(packet+24,0x20003);put32(packet+28,7);put32(packet+32,9);put32(packet+48,0x314a424d);put16(packet+52,1);put16(packet+54,1);memcpy(packet+56,graph,32);put16(packet+88,0);
 assert(microblossom_service_decode((cyt_provider*)1,packet,sizeof(packet),edges,&count,&ops)==0);assert(count==1&&edges[0]==2);assert(reads==4&&writes==6);
 microblossom_service_make_response(packet,response,0,edges,count,ops);
 assert(response[5]==2&&response[24]==4&&response[28]==9&&response[32]==7);
 assert(response[48]=='M'&&response[49]=='B'&&response[50]=='R'&&response[51]=='1');
 assert(response[88]==1&&response[90]==10&&response[92]==2);
 packet[24]=4;assert(microblossom_service_decode((cyt_provider*)1,packet,sizeof(packet),edges,&count,&ops)==1);packet[24]=3;
 puts("MICROBLOSSOM_R5_SERVICE_PASS");return 0;
}
