#include "udp_api.h"

#include <string.h>

#ifndef UDP_ENGINE_MMIO_BASE
#define UDP_ENGINE_MMIO_BASE ((uintptr_t)0)
#endif

/*
 * The checked-in MicroBlaze design has C_USE_DCACHE=0.  If a later BSP turns
 * the data cache on, define these two macros to Xil_DCacheFlushRange and
 * Xil_DCacheInvalidateRange (or equivalent uncached-region operations).
 */
#ifndef UDP_CACHE_FLUSH_RANGE
#define UDP_CACHE_FLUSH_RANGE(address, length) ((void)(address), (void)(length))
#endif
#ifndef UDP_CACHE_INVALIDATE_RANGE
#define UDP_CACHE_INVALIDATE_RANGE(address, length) ((void)(address), (void)(length))
#endif

#define REG_DMA_BASE       0x00u
#define REG_RX0_CONFIG     0x04u
#define REG_RX0_HEAD       0x08u
#define REG_RX0_TAIL       0x0Cu
#define REG_RX1_CONFIG     0x10u
#define REG_RX1_HEAD       0x14u
#define REG_RX1_TAIL       0x18u
#define REG_TX_HEAD        0x1Cu
#define REG_TX_TAIL        0x20u
#define REG_LOCAL_IP       0x24u
#define REG_SUBNET_MASK    0x28u
#define REG_GATEWAY        0x2Cu

#define SOCKET_ENABLE      0x80000000u
#define ENTRY_BYTES        1500u
#define METADATA_BYTES     16u
#define MAX_PAYLOAD_BYTES  1472u
#define RX1_OFFSET         4500u
#define TX_OFFSET          9000u
#define DMA_REGION_BYTES   15000u

typedef struct {
    uint8_t open;
    uint16_t port;
} socket_state_t;

static uintptr_t g_mmio_base = UDP_ENGINE_MMIO_BASE;
static uintptr_t g_dma_base;
static socket_state_t g_sockets[2];
static uint8_t g_initialized;

static inline volatile uint32_t *mmio_reg(uint32_t offset)
{
    return (volatile uint32_t *)(g_mmio_base + (uintptr_t)offset);
}

static inline uint32_t reg_read(uint32_t offset)
{
    return *mmio_reg(offset);
}

static inline void reg_write(uint32_t offset, uint32_t value)
{
    *mmio_reg(offset) = value;
}

static inline void memory_barrier(void)
{
#if defined(__microblaze__)
    __asm__ volatile("mbar 1" ::: "memory");
#elif defined(__GNUC__)
    __sync_synchronize();
#else
    (void)0;
#endif
}

static inline uint32_t ptr_index(uint32_t ptr)
{
    return ptr & 0x3u;
}

static inline uint32_t tx_ptr_advance(uint32_t ptr)
{
    return (ptr + 1u) & 0x7u;
}

static inline uint32_t rx_ptr_advance(uint32_t ptr)
{
    uint32_t index = ptr_index(ptr);
    uint32_t wrap = ptr & 0x4u;
    if (index == 2u) {
        return (wrap ^ 0x4u);
    }
    return wrap | (index + 1u);
}

static inline int queue_full(uint32_t head, uint32_t tail)
{
    return ptr_index(head) == ptr_index(tail) && ((head ^ tail) & 0x4u) != 0u;
}

static uintptr_t entry_address(uintptr_t region_offset, uint32_t index)
{
    return g_dma_base + region_offset + (uintptr_t)(index * ENTRY_BYTES);
}

static uint32_t socket_config_reg(udp_socket_t socket)
{
    return socket == 0 ? REG_RX0_CONFIG : REG_RX1_CONFIG;
}

static uint32_t socket_head_reg(udp_socket_t socket)
{
    return socket == 0 ? REG_RX0_HEAD : REG_RX1_HEAD;
}

static uint32_t socket_tail_reg(udp_socket_t socket)
{
    return socket == 0 ? REG_RX0_TAIL : REG_RX1_TAIL;
}

static int socket_is_valid(udp_socket_t socket)
{
    return socket >= 0 && socket < 2 && g_sockets[socket].open != 0u;
}

void udp_set_mmio_base(uintptr_t mmio_base)
{
    g_mmio_base = mmio_base;
}

int udp_init(const udp_config_t *config)
{
    uint32_t rx0_tail;
    uint32_t rx1_tail;
    uint32_t tx_head;

    if (config == NULL || g_mmio_base == (uintptr_t)0 ||
        (config->dma_base & 0x3u) != 0u || config->local_ip == 0u ||
        config->local_ip == 0xFFFFFFFFu || config->subnet_mask == 0u ||
        config->dma_base > (uintptr_t)(UINT32_MAX - (DMA_REGION_BYTES - 1u))) {
        return UDP_ERR_ARGUMENT;
    }

    reg_write(REG_RX0_CONFIG, 0u);
    reg_write(REG_RX1_CONFIG, 0u);
    g_sockets[0].open = 0u;
    g_sockets[1].open = 0u;

    reg_write(REG_DMA_BASE, (uint32_t)config->dma_base);
    reg_write(REG_LOCAL_IP, config->local_ip);
    reg_write(REG_SUBNET_MASK, config->subnet_mask);
    reg_write(REG_GATEWAY, config->default_gateway);

    rx0_tail = reg_read(REG_RX0_TAIL) & 0x7u;
    rx1_tail = reg_read(REG_RX1_TAIL) & 0x7u;
    tx_head = reg_read(REG_TX_HEAD) & 0x7u;
    reg_write(REG_RX0_HEAD, rx0_tail);
    reg_write(REG_RX1_HEAD, rx1_tail);
    reg_write(REG_TX_TAIL, tx_head);

    UDP_CACHE_FLUSH_RANGE(config->dma_base, DMA_REGION_BYTES);
    UDP_CACHE_INVALIDATE_RANGE(config->dma_base, DMA_REGION_BYTES);
    memory_barrier();

    g_dma_base = config->dma_base;
    g_initialized = 1u;
    return UDP_OK;
}

udp_socket_t udp_socket_open(uint16_t local_port)
{
    udp_socket_t socket;
    uint32_t tail;

    if (!g_initialized) {
        return UDP_ERR_NOT_INITIALIZED;
    }
    if (local_port == 0u) {
        return UDP_ERR_ARGUMENT;
    }
    for (socket = 0; socket < 2; ++socket) {
        if (g_sockets[socket].open && g_sockets[socket].port == local_port) {
            return UDP_ERR_PORT_IN_USE;
        }
    }
    for (socket = 0; socket < 2; ++socket) {
        if (!g_sockets[socket].open) {
            reg_write(socket_config_reg(socket), 0u);
            tail = reg_read(socket_tail_reg(socket)) & 0x7u;
            reg_write(socket_head_reg(socket), tail);
            memory_barrier();
            reg_write(socket_config_reg(socket), SOCKET_ENABLE | local_port);
            g_sockets[socket].port = local_port;
            g_sockets[socket].open = 1u;
            return socket;
        }
    }
    return UDP_ERR_NO_SOCKET;
}

int udp_socket_close(udp_socket_t socket)
{
    uint32_t tail;
    if (!g_initialized) {
        return UDP_ERR_NOT_INITIALIZED;
    }
    if (!socket_is_valid(socket)) {
        return UDP_ERR_ARGUMENT;
    }
    reg_write(socket_config_reg(socket), 0u);
    tail = reg_read(socket_tail_reg(socket)) & 0x7u;
    reg_write(socket_head_reg(socket), tail);
    g_sockets[socket].open = 0u;
    g_sockets[socket].port = 0u;
    return UDP_OK;
}

int udp_send(udp_socket_t socket, const void *payload,
             uint16_t payload_length, uint32_t destination_ip,
             uint16_t destination_port)
{
    uint32_t head;
    uint32_t tail;
    uintptr_t address;
    volatile uint32_t *metadata;

    if (!g_initialized) {
        return UDP_ERR_NOT_INITIALIZED;
    }
    if (!socket_is_valid(socket) || destination_ip == 0u ||
        destination_ip == 0xFFFFFFFFu || destination_port == 0u ||
        payload_length > MAX_PAYLOAD_BYTES || (payload_length != 0u && payload == NULL)) {
        return UDP_ERR_ARGUMENT;
    }

    do {
        head = reg_read(REG_TX_HEAD) & 0x7u;
        tail = reg_read(REG_TX_TAIL) & 0x7u;
    } while (queue_full(head, tail));

    address = entry_address(TX_OFFSET, ptr_index(tail));
    metadata = (volatile uint32_t *)address;
    metadata[0] = destination_ip;
    metadata[1] = ((uint32_t)g_sockets[socket].port << 16) | destination_port;
    metadata[2] = payload_length;
    metadata[3] = 0u;
    if (payload_length != 0u) {
        memcpy((void *)(address + METADATA_BYTES), payload, payload_length);
    }

    UDP_CACHE_FLUSH_RANGE(address, METADATA_BYTES + payload_length);
    memory_barrier();
    reg_write(REG_TX_TAIL, tx_ptr_advance(tail));
    return UDP_OK;
}

int udp_recv(udp_socket_t socket, void *payload,
             uint16_t payload_capacity, udp_info_t *info)
{
    uint32_t head;
    uint32_t tail;
    uint32_t length;
    uintptr_t region_offset;
    uintptr_t address;
    volatile const uint32_t *metadata;

    if (!g_initialized) {
        return UDP_ERR_NOT_INITIALIZED;
    }
    if (!socket_is_valid(socket) || info == NULL ||
        (payload_capacity != 0u && payload == NULL)) {
        return UDP_ERR_ARGUMENT;
    }

    do {
        head = reg_read(socket_head_reg(socket)) & 0x7u;
        tail = reg_read(socket_tail_reg(socket)) & 0x7u;
    } while (head == tail);

    region_offset = socket == 0 ? 0u : RX1_OFFSET;
    address = entry_address(region_offset, ptr_index(head));
    UDP_CACHE_INVALIDATE_RANGE(address, ENTRY_BYTES);
    memory_barrier();

    metadata = (volatile const uint32_t *)address;
    length = metadata[2] & 0xFFFFu;
    if (length > MAX_PAYLOAD_BYTES) {
        return UDP_ERR_ARGUMENT;
    }
    if (length > payload_capacity) {
        return UDP_ERR_BUFFER_TOO_SMALL;
    }

    info->source_ip = metadata[0];
    info->source_port = (uint16_t)(metadata[1] & 0xFFFFu);
    info->destination_port = (uint16_t)(metadata[1] >> 16);
    info->payload_length = (uint16_t)length;
    info->flags = (uint16_t)(metadata[2] >> 16);
    if (length != 0u) {
        memcpy(payload, (const void *)(address + METADATA_BYTES), length);
    }

    memory_barrier();
    reg_write(socket_head_reg(socket), rx_ptr_advance(head));
    return (int)length;
}
