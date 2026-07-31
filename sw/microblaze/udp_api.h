#ifndef UDP_API_H
#define UDP_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int udp_socket_t;

typedef struct {
    uint32_t source_ip;
    uint16_t source_port;
    uint16_t destination_port;
    uint16_t payload_length;
    uint16_t flags;
} udp_info_t;

typedef struct {
    uintptr_t dma_base;
    uint32_t local_ip;
    uint32_t subnet_mask;
    uint32_t default_gateway;
} udp_config_t;

enum {
    UDP_OK = 0,
    UDP_ERR_ARGUMENT = -1,
    UDP_ERR_NOT_INITIALIZED = -2,
    UDP_ERR_NO_SOCKET = -3,
    UDP_ERR_PORT_IN_USE = -4,
    UDP_ERR_BUFFER_TOO_SMALL = -5
};

/* Optional when UDP_ENGINE_MMIO_BASE is supplied by the BSP/build system. */
void udp_set_mmio_base(uintptr_t mmio_base);

int udp_init(const udp_config_t *config);
udp_socket_t udp_socket_open(uint16_t local_port);
int udp_socket_close(udp_socket_t socket);
int udp_send(udp_socket_t socket, const void *payload,
             uint16_t payload_length, uint32_t destination_ip,
             uint16_t destination_port);
int udp_recv(udp_socket_t socket, void *payload,
             uint16_t payload_capacity, udp_info_t *info);

#ifdef __cplusplus
}
#endif

#endif
