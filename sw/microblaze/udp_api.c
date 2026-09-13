#include "udp_api.h"
#include <stddef.h>

/*
Memory Map of 'fpga_network_engine':


0x0 | TX/RX Queue Base Addr | R/W | Base address of the TX/RX queue memory region


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

/*
* Configuration Register Offsets
*/
#define QUEUE_BASE_ADDR_OFFSET      0x0
#define IPV4_ADDR_OFFSET            0x24
#define SUBNET_MASK_OFFSET          0x28
#define GATEWAY_OFFSET              0x2C

#define QUEUE_MEM_SIZE 

static uintptr_t UDP_ENGINE_MMIO_BASE = -1;
static uintptr_t QUEUE_BASE_ADDR;

static int UDP_ENGINE_INITIALIZED = 0;

void udp_set_mmio_base(uintptr_t mmio_base) {
    UDP_ENGINE_MMIO_BASE = mmio_base;
}

/*
* Provide the base address of the TX/RX queues memory region, the local IPv4 address, the subnet mask,
* and the default gateway

* The 'fpga_network_engine' will be passed this information by setting particular registers in its address space.

* config: A struct that has fields for all the above information 
*/
int udp_init(const udp_config_t *config) {
    if (config == NULLPTR) {
        return UDP_ERR_ARGUMENT;
    }

    // UDP Engine MMIO base address not provided
    if (UDP_ENGINE_MMIO_BASE = -1) {
        return UDP_ERR_ARGUMENT;
    }

    // Verify word-aligned address
    if ((config->queue_base_addr % 4) != 0) {
        return UDP_ERR_ARGUMENT;
    }

    if ((config->queue_base_addr + ))

    volatile uint32_t* QUEUE_BASE_ADDR = (volatile uint32_t*)(UDP_ENGINE_MMIO_BASE + QUEUE_BASE_ADDR_OFFSET);
    *QUEUE_BASE_ADDR = config->queue_base_addr;
    QUEUE_BASE_ADDR = config->queue_base_addr;

    volatile uint32_t* SUBNET_MASK = (volatile uint32_t*)(UDP_ENGINE_MMIO_BASE + SUBNET_MASK_OFFSET);
    *SUBNET_MASK = config->subnet_mask;

    volatile uint32_t* GATEWAY = (volatile uint32_t*)(UDP_ENGINE_MMIO_BASE + GATEWAY_OFFSET);
    *GATEWAY = config->default_gateway;

    volatile uint32_t* IPV4_ADDR = (volatile uint32_t*)(UDP_ENGINE_MMIO_BASE + IPV4_ADDR_OFFSET);
    *IPV4_ADDR = config->local_ip;

    UDP_ENGINE_INITIALIZED = 1;
    return UDP_OK;
}