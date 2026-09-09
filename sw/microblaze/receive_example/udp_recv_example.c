#include "udp_api.h"
#include <stddef.h>
#include <string.h>

#define UDP_ENGINE_MMIO_BASE ((uintptr_t)0x00020000u)
#define UDP_PACKET_RAM_BASE  ((uintptr_t)0x00010000u)

#define FPGA_IPV4_ADDRESS  0xA9FE0164u
#define FPGA_SUBNET_MASK   0xFFFF0000u
#define FPGA_GATEWAY       0x00000000u
#define PC_IPV4_ADDRESS    0xA9FEC246u

#define FPGA_SOURCE_PORT   1234u
#define PC_DESTINATION_PORT 4321u

#define PAYLOAD_BUFFER_LENGTH 100

#define EXPECTED_PACKETS 10

int main(void) {

    int expected_payload_lengths[] = 
        {1, 5, 8, 18, 25, 36, 49, 62, 66, 66};
    char payload_buffer[PAYLOAD_BUFFER_LENGTH]; 
    
    
    const udp_config_t config = {
        .dma_base = UDP_PACKET_RAM_BASE,
        .local_ip = FPGA_IPV4_ADDRESS,
        .subnet_mask = FPGA_SUBNET_MASK,
        .default_gateway = FPGA_GATEWAY
    };
    udp_socket_t socket;
    int result;

    udp_set_mmio_base(UDP_ENGINE_MMIO_BASE);

    result = udp_init(&config);
    if (result != UDP_OK) {
        return result;
    }

    socket = udp_socket_open(FPGA_SOURCE_PORT);
    if (socket < 0) {
        return socket;
    }

    for (int i = 0; i < EXPECTED_PACKETS; i++) {
        udp_info_t recv_packet_info;
        udp_recv(socket, payload_buffer, PAYLOAD_BUFFER_LENGTH, &recv_packet_info);
        if (recv_packet_info.source_ip != PC_IPV4_ADDRESS) {
            return -1;
        }
        if (recv_packet_info.destination_port != FPGA_SOURCE_PORT) {
            return -1;
        }
        if (recv_packet_info.payload_length != expected_payload_lengths[i]) {
            return -1;
        }
    }


    return 0;
}