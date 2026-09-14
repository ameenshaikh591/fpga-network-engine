#include "udp_api.h"
#include <stddef.h>

/*
Memory Map of UDP Engine (32-bit registers):
   ---------------------------------------------------------------------------------------
   | Offset | Register           | Access | Description                                  |
   |--------|--------------------|--------|----------------------------------------------|
   |  0x00  | TX/RX Queue Base   | R/W    | Base address of TX/RX queue memory           | 
   |  0x04  | RX0 Config         | R/W    | bit 31: enable ; bits 15:0: local UDP port   |
   |  0x08  | RX0 Head           | R/W    | Next RX0 entry for software to consume       |
   |  0x0C  | RX0 Tail           | R      | Next RX0 entry for hardware to produce       |
   |  0x10  | RX1 Config         | R/W    | bit 31: enable ; bits 15:0: local UDP port   |
   |  0x14  | RX1 Head           | R/W    | Next RX1 entry for software to consume       |
   |  0x18  | RX1 Tail           | R      | Next RX1 entry for hardware to produce       |
   |  0x1C  | TX Head            | R      | Next TX entry for hardware to consume        |
   |  0x20  | TX Tail            | R/W    | Next TX entry for software to produce        |
   |  0x24  | Local IPv4 Address | R/W    | Local IPv4 address                           |
   |  0x28  | Subnet Mask        | R/W    | Local subnet mask                            |
   |  0x2C  | Default Gateway    | R/W    | Gateway IPv4 address; zero if unused         |
   ---------------------------------------------------------------------------------------

Queue pointers: bits 1:0 hold the entry index; bit 2 is the wrap bit.
*/

/*
* Configuration Register Offsets
*/
#define QUEUE_BASE_ADDR_OFFSET      0x0

#define RX0_CONFIG_OFFSET           0x4
#define RX0_HEAD_OFFSET             0x8
#define RX0_TAIL_OFFSET             0xC

#define RX1_CONFIG_OFFSET           0x10
#define RX1_HEAD_OFFSET             0x14
#define RX1_TAIL_OFFSET             0x18

#define LOCAL_IP_OFFSET             0x24
#define SUBNET_MASK_OFFSET          0x28
#define GATEWAY_OFFSET              0x2C

#define QUEUE_REGION_BYTES          15000

static uintptr_t mmio_base = UINTPTR_MAX;
static uintptr_t queue_base_addr;

static int initialized = 0;

void udp_set_mmio_base(uintptr_t mmio_base_arg) {
    mmio_base = mmio_base_arg;
}

/*
* Provide the base address of the TX/RX queues memory region, the local IPv4 address, the subnet mask,
* and the default gateway

* The 'UDP Engine' will be passed this information by setting particular registers in its address space.

* config: A struct that has fields for all the above information 
*/
int udp_init(const udp_config_t *config) {
    if (config == NULL) {
        return UDP_ERR_ARGUMENT;
    }

    // Verify UDP Engine MMIO base address was provided
    if (mmio_base == UINTPTR_MAX) {
        return UDP_ERR_ARGUMENT;
    }

    // Verify word-aligned address
    if ((config->queue_base_addr % 4) != 0) {
        return UDP_ERR_ARGUMENT;
    }


    if ((0xFFFFFFFFu - QUEUE_REGION_BYTES + 1) < config->queue_base_addr) {
        return UDP_ERR_ARGUMENT;
    }

    volatile uint32_t* queue_base_reg = (volatile uint32_t*)(mmio_base + QUEUE_BASE_ADDR_OFFSET);
    *queue_base_reg = (uint32_t)config->queue_base_addr;
    queue_base_addr = config->queue_base_addr;

    volatile uint32_t* subnet_mask_reg = (volatile uint32_t*)(mmio_base + SUBNET_MASK_OFFSET);
    *subnet_mask_reg = config->subnet_mask;

    volatile uint32_t* gateway_reg = (volatile uint32_t*)(mmio_base + GATEWAY_OFFSET);
    *gateway_reg = config->default_gateway;

    volatile uint32_t* local_ip_reg = (volatile uint32_t*)(mmio_base + LOCAL_IP_OFFSET);
    *local_ip_reg = config->local_ip;

    initialized = 1;
    return UDP_OK;
}


/*
* Attempt to create a UDP socket and pass it a port
* If a UDP socket cannot be created (all RX queues are taken), return UDP_ERR_NO_SOCKET
* Otherwise, return the selected socket handle (0 or 1)
*/
udp_socket_t udp_socket_open(uint16_t local_port) {
    // Bit 31 of "RX0 Config" and "RX1 Config" specify if RX0/RX1 queues are reserved by active sockets
    // We must have a queue to reserve in order to establish a socket

    // The provided port must not conflict with an active port

    if (local_port == 0) {
        return UDP_ERR_ARGUMENT;
    }

    if (initialized == 0) {
        return UDP_ERR_NOT_INITIALIZED;
    }

    uint8_t rx0_free = 0;
    uint8_t rx1_free = 0;

    volatile uint32_t* rx0_config_reg = (volatile uint32_t*)(mmio_base + RX0_CONFIG_OFFSET);
    if ((*rx0_config_reg & 0x80000000u) != 0) {
        uint16_t rx0_active_port = (uint16_t)(*rx0_config_reg & 0x0000FFFF);
        if (rx0_active_port == local_port) {
            return UDP_ERR_PORT_IN_USE;
        }
    } else {
        rx0_free = 1;
    }

    volatile uint32_t* rx1_config_reg = (volatile uint32_t*)(mmio_base + RX1_CONFIG_OFFSET);
    if ((*rx1_config_reg & 0x80000000u) != 0) {
        uint16_t rx1_active_port = (uint16_t)(*rx1_config_reg & 0x0000FFFF);
        if (rx1_active_port == local_port) {
            return UDP_ERR_PORT_IN_USE;
        }
    } else {
        rx1_free = 1;
    }

    if (!rx0_free && !rx1_free) {
        return UDP_ERR_NO_SOCKET;
    }

    volatile uint32_t* rx0_head_reg = (volatile uint32_t*)(mmio_base + RX0_HEAD_OFFSET);
    volatile uint32_t* rx0_tail_reg = (volatile uint32_t*)(mmio_base + RX0_TAIL_OFFSET);
    volatile uint32_t* rx1_head_reg = (volatile uint32_t*)(mmio_base + RX1_HEAD_OFFSET);
    volatile uint32_t* rx1_tail_reg = (volatile uint32_t*)(mmio_base + RX1_TAIL_OFFSET);
    if (rx0_free) {
        // Make sure existing queue contents are cleared
        uint8_t rx0_tail = (uint8_t)(*rx0_tail_reg);
        *rx0_head_reg = (uint32_t)(rx0_tail);

        *rx0_config_reg = 0x80000000u | (uint32_t)local_port;
        return 0;
    } else {
        // Make sure existing queue contents are cleared
        uint8_t rx1_tail = (uint8_t)(*rx1_tail_reg);
        *rx1_head_reg = (uint32_t)(rx1_tail);

        *rx1_config_reg = 0x80000000u | (uint32_t)local_port;
        return 1;
    }
}

/*
* Close an established UDP socket, freeing up an RX queue
*/
int udp_socket_close(udp_socket_t socket) {
    if (socket > 1 || socket < 0) {
        return UDP_ERR_ARGUMENT;
    }

    if (initialized == 0) {
        return UDP_ERR_NOT_INITIALIZED;
    }

    volatile uint32_t* rx_config_reg;
    volatile uint32_t* rx_head_reg;
    volatile uint32_t* rx_tail_reg;

    if (socket == 0) {
        rx_config_reg = (volatile uint32_t*)(mmio_base + RX0_CONFIG_OFFSET);
        rx_head_reg = (volatile uint32_t*)(mmio_base + RX0_HEAD_OFFSET);
        rx_tail_reg = (volatile uint32_t*)(mmio_base + RX0_TAIL_OFFSET);
    } else {
        rx_config_reg = (volatile uint32_t*)(mmio_base + RX1_CONFIG_OFFSET);
        rx_head_reg = (volatile uint32_t*)(mmio_base + RX1_HEAD_OFFSET);
        rx_tail_reg = (volatile uint32_t*)(mmio_base + RX1_TAIL_OFFSET);
    }

    *rx_config_reg = 0x00000000u;

    uint8_t rx_tail = (uint8_t)(*rx_tail_reg);
    *rx_head_reg = rx_tail;
    return UDP_OK;
}