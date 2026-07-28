#include "udp_api.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Vivado address-map assignments. */
#define UDP_ENGINE_MMIO_BASE ((uintptr_t)0x00020000u)
#define UDP_PACKET_RAM_BASE  ((uintptr_t)0x00010000u)

#define FPGA_IPV4_ADDRESS  0xA9FE0164u
#define FPGA_SUBNET_MASK   0xFFFF0000u
#define FPGA_GATEWAY       0x00000000u
#define PC_IPV4_ADDRESS    0xA9FEC246u

#define FPGA_SOURCE_PORT   1234u
#define PC_DESTINATION_PORT 4321u

#define PAYLOAD_BUFFER_LENGTH 100

int main(void)
{
    char payload_buffer[PAYLOAD_BUFFER_LENGTH];
    size_t payload_length;

    snprintf(payload_buffer, sizeof(payload_buffer), "%s", "hello from fpga!\n");
    payload_length = strlen(payload_buffer) - 1;
    
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

    result = udp_send(socket, payload_buffer, (uint16_t)payload_length,
                                 PC_IPV4_ADDRESS, PC_DESTINATION_PORT);
    if (result != UDP_OK) {
        return result;
    }

    while (1) {}
}
