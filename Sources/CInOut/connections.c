#include "include/CInOut.h"

#include <arpa/inet.h>
#include <libproc.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>

static void inout_format_addr(uint8_t vflag, const void *addr, char *out)
{
    out[0] = '\0';
    if (vflag & INI_IPV4) {
        const struct in4in6_addr *a = (const struct in4in6_addr *)addr;
        inet_ntop(AF_INET, &a->i46a_addr4, out, INOUT_ADDR_MAX);
    } else if (vflag & INI_IPV6) {
        inet_ntop(AF_INET6, addr, out, INOUT_ADDR_MAX);
    }
}

int inout_read_connections(InOutConnection *buf, int cap)
{
    if (!buf || cap <= 0) {
        return -1;
    }

    int sized = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (sized <= 0) {
        return -1;
    }

    /* Headroom: processes can spawn between the sizing call and the read. */
    int slots = (int)(sized / (int)sizeof(pid_t)) + 64;
    pid_t *pids = calloc((size_t)slots, sizeof(pid_t));
    if (!pids) {
        return -1;
    }

    int got = proc_listpids(PROC_ALL_PIDS, 0, pids,
                           (int)((size_t)slots * sizeof(pid_t)));
    if (got <= 0) {
        free(pids);
        return -1;
    }

    int npids = (int)((size_t)got / sizeof(pid_t));
    int written = 0;

    for (int i = 0; i < npids && written < cap; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) {
            continue;
        }

        int fdsize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fdsize <= 0) {
            continue; /* not ours, or exited */
        }

        struct proc_fdinfo *fds = malloc((size_t)fdsize);
        if (!fds) {
            continue;
        }
        int fdgot = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fdsize);
        if (fdgot <= 0) {
            free(fds);
            continue;
        }

        int nfds = fdgot / PROC_PIDLISTFD_SIZE;
        char pname[INOUT_PROCNAME_MAX];
        int have_name = 0;

        for (int j = 0; j < nfds && written < cap; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) {
                continue;
            }

            struct socket_fdinfo si;
            int r = proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO,
                                   &si, PROC_PIDFDSOCKETINFO_SIZE);
            if (r != PROC_PIDFDSOCKETINFO_SIZE) {
                continue;
            }

            int kind = si.psi.soi_kind;
            if (kind != SOCKINFO_TCP && kind != SOCKINFO_IN) {
                continue;
            }

            const struct in_sockinfo *ini;
            uint8_t proto;
            uint8_t state;

            if (kind == SOCKINFO_TCP) {
                ini   = &si.psi.soi_proto.pri_tcp.tcpsi_ini;
                proto = IPPROTO_TCP;
                state = (uint8_t)si.psi.soi_proto.pri_tcp.tcpsi_state;
            } else {
                ini   = &si.psi.soi_proto.pri_in;
                proto = IPPROTO_UDP;
                state = 0;
            }

            uint8_t vflag = ini->insi_vflag;
            if (!(vflag & (INI_IPV4 | INI_IPV6))) {
                continue;
            }

            if (!have_name) {
                pname[0] = '\0';
                if (proc_name(pid, pname, sizeof(pname)) <= 0) {
                    snprintf(pname, sizeof(pname), "pid %d", pid);
                }
                have_name = 1;
            }

            InOutConnection *out = &buf[written++];
            memset(out, 0, sizeof(*out));
            out->pid = pid;
            memcpy(out->process, pname,
                   strnlen(pname, INOUT_PROCNAME_MAX - 1));
            inout_format_addr(vflag, &ini->insi_laddr, out->local_addr);
            inout_format_addr(vflag, &ini->insi_faddr, out->remote_addr);
            out->local_port  = ntohs((uint16_t)ini->insi_lport);
            out->remote_port = ntohs((uint16_t)ini->insi_fport);
            out->family      = (vflag & INI_IPV4) ? 4 : 6;
            out->proto       = proto;
            out->state       = state;
        }

        free(fds);
    }

    free(pids);
    return written;
}
