#ifndef UDP_API_H
#define UDP_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
Memory Map of UDP Engine:


0x0 | Queue Base Addr | R/W | Base address of the TX/RX queue memory region


0x4 | RX0 Config    | R/W | 
    Bitmap: 
        Bit [31] : Socket Enable
        Bits [30:0] : UDP Local Port
0x8 | RX0 Head | R/W | 
0xC | RX0 Tail | R

0x10 | RX1 Config | R/W |
    Bitmap: 
        Bit [31] : Socket Enable
        Bits [30:0] : UDP Local Port
0x14 | RX1 Head | R/W | 
0x18 | RX1 Tail | R

0x1C | TX Head | R
0x20 | TX Tail | R/W 

0x24 | Local IPv4 Address | R/W
0x28 | Subnet Mask | R/W
0x2C | Default Gateway | R/W |


*/

typedef int udp_socket_t;

typedef struct {
    uint32_t source_ip;
    uint16_t source_port;
    uint16_t destination_port;
    uint16_t payload_length;
    uint16_t flags;
} udp_info_t;

typedef struct {
    uintptr_t queue_base_addr;
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

/*
* The user provides the MMIO base address of the UDP Engine peripheral
* mmio_base: The base address of the UDP Engine peripheral
*/
void udp_set_mmio_base(uintptr_t mmio_base);

/*
* Provide the base address of the TX/RX queues memory region, the local IPv4 address, the subnet mask,
* and the default gateway.

* The UDP Engine will be passed this information by setting particular registers in its address space.

* config: A struct that has fields for all the above information 

* Need to handle the improper condition where 'udp_init()' is called before 'udp_set_mmio_base()'
*/
int udp_init(const udp_config_t *config);

/*
* Attempt to create a UDP socket and pass it a port
* If a UDP socket cannot be created (all RX queues are taken), return UDP_ERR_NO_SOCKET
* Otherwise, return the passed in local port
*/
udp_socket_t udp_socket_open(uint16_t local_port);

/*
* Close an established UDP socket, freeing up an RX queue
*/
int udp_socket_close(udp_socket_t socket);

/*
* Queues transmission of a UDP packet
*/
int udp_send(udp_socket_t socket, const void *payload, uint16_t payload_length, uint32_t destination_ip,
    uint16_t destination_port);

/*
* Receives a queued UDP packet belonging to the provided socket
*/
int udp_recv(udp_socket_t socket, void *payload, uint16_t payload_capacity, udp_info_t *info);

#ifdef __cplusplus
}
#endif

#endif
