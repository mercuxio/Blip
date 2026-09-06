#include "include/CBlip.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_mib.h>
#include <net/route.h>

int blip_read_ifmib(BlipIfCounters *buf, int cap)
{
    if (!buf || cap <= 0) {
        return -1;
    }

    int mib[6];
    size_t len;
    int count = 0;

    mib[0] = CTL_NET;
    mib[1] = PF_LINK;
    mib[2] = NETLINK_GENERIC;
    mib[3] = IFMIB_SYSTEM;
    mib[4] = IFMIB_IFCOUNT;
    len = sizeof(count);
    if (sysctl(mib, 5, &count, &len, NULL, 0) < 0) {
        return -1;
    }

    int written = 0;
    for (int row = 1; row <= count && written < cap; row++) {
        struct ifmibdata data;
        len = sizeof(data);

        mib[0] = CTL_NET;
        mib[1] = PF_LINK;
        mib[2] = NETLINK_GENERIC;
        mib[3] = IFMIB_IFDATA;
        mib[4] = row;
        mib[5] = IFDATA_GENERAL;

        /* A row can disappear between the count and the read; skip, don't fail. */
        if (sysctl(mib, 6, &data, &len, NULL, 0) < 0) {
            continue;
        }

        BlipIfCounters *out = &buf[written++];
        memset(out, 0, sizeof(*out));
        memcpy(out->name, data.ifmd_name,
               strnlen(data.ifmd_name, BLIP_IFNAME_MAX - 1));
        out->ibytes = data.ifmd_data.ifi_ibytes;
        out->obytes = data.ifmd_data.ifi_obytes;
        out->flags  = data.ifmd_flags;
        out->type   = data.ifmd_data.ifi_type;
    }

    return written;
}

int blip_read_iflist2(BlipIfCounters *buf, int cap)
{
    if (!buf || cap <= 0) {
        return -1;
    }

    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t len = 0;
    char *raw = NULL;

    /*
     * Classic sysctl sizing race: the table can grow between the sizing call
     * and the read. Retry a bounded number of times on ENOMEM.
     */
    for (int attempt = 0; attempt < 5; attempt++) {
        if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) {
            return -1;
        }
        raw = malloc(len);
        if (!raw) {
            return -1;
        }
        if (sysctl(mib, 6, raw, &len, NULL, 0) == 0) {
            break;
        }
        free(raw);
        raw = NULL;
        if (errno != ENOMEM) {
            return -1;
        }
    }
    if (!raw) {
        return -1;
    }

    int written = 0;
    char *limit = raw + len;
    char *cursor = raw;

    while (cursor < limit && written < cap) {
        struct if_msghdr *hdr = (struct if_msghdr *)cursor;
        if (hdr->ifm_msglen == 0) {
            break;
        }
        cursor += hdr->ifm_msglen;

        if (hdr->ifm_type != RTM_IFINFO2) {
            continue;
        }

        struct if_msghdr2 *hdr2 = (struct if_msghdr2 *)hdr;
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)(hdr2 + 1);

        BlipIfCounters *out = &buf[written++];
        memset(out, 0, sizeof(*out));
        int nlen = sdl->sdl_nlen;
        if (nlen > BLIP_IFNAME_MAX - 1) {
            nlen = BLIP_IFNAME_MAX - 1;
        }
        memcpy(out->name, sdl->sdl_data, nlen);
        out->ibytes = hdr2->ifm_data.ifi_ibytes;
        out->obytes = hdr2->ifm_data.ifi_obytes;
        out->flags  = hdr2->ifm_flags;
        out->type   = hdr2->ifm_data.ifi_type;
    }

    free(raw);
    return written;
}
