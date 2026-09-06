#ifndef CBLIP_H
#define CBLIP_H

#include <stdint.h>

#define BLIP_IFNAME_MAX   16

typedef struct {
    char     name[BLIP_IFNAME_MAX];
    uint64_t ibytes;
    uint64_t obytes;
    uint32_t flags;   /* IFF_* */
    uint32_t type;    /* IFT_* */
} BlipIfCounters;

/*
 * Primary counter source.
 *
 * net.link.generic.ifdata.<row>.general  (IFMIB_IFDATA -> struct ifmibdata)
 *
 * Returns true, untruncated 64-bit byte counters. Verified against
 * `netstat -ib` to the byte. Returns rows written, or -1 on failure.
 */
int blip_read_ifmib(BlipIfCounters *buf, int cap);

/*
 * Fallback / cross-check counter source.
 *
 * sysctl NET_RT_IFLIST2 -> if_msghdr2.ifm_data (declared if_data64)
 *
 * On current macOS this path returns values truncated to 32 bits AND floored
 * to a 1 KiB multiple, despite the 64-bit struct field. It is kept ONLY so
 * that CounterSourceSelector can detect at launch whether ifmib has started
 * being sanitized the same way, and degrade deliberately instead of silently
 * reporting a fraction of reality. Returns rows written, or -1.
 */
int blip_read_iflist2(BlipIfCounters *buf, int cap);

#endif /* CBLIP_H */
