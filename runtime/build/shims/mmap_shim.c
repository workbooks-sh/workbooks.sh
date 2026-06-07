/*
 * mmap_shim.c — file-backed mmap/munmap/msync over pread/pwrite for wasm32-wasi.
 *
 * wasi-libc ships no mmap (there is no virtual-memory syscall to forward — the
 * guest's loads/stores never trap out to the host). But the COMMON CLI use of
 * mmap is "map a file, read/write through the pointer", which is faithfully
 * emulatable: allocate a buffer, pread the file into it, and (for MAP_SHARED)
 * pwrite the buffer back on msync/munmap. The WASI file ops (pread/pwrite) DO
 * route to the host, so the round-trip is real.
 *
 * Link this object into any C/wasi CLI that calls mmap, with the linker flags
 *   -Wl,--wrap=mmap -Wl,--wrap=munmap -Wl,--wrap=msync
 * so calls to mmap/munmap/msync resolve to __wrap_* here, leaving the CLI source
 * untouched. (Newer wasi-libc ships its OWN mmap that just returns ENOSYS, so a
 * plain duplicate definition collides — --wrap redirects cleanly past it.)
 * See docs/TOOLKITS-V3.org §FS bridge.
 *
 * Limits (documented, rare for CLIs): no lazy demand-paging (the whole region is
 * eager-loaded, so files near/over the wasm32 ~4 GiB address space don't fit),
 * anonymous shared mappings used purely for cross-process IPC are not faithful
 * (separate sandboxes share no address space). MAP_ANONYMOUS|MAP_PRIVATE (a
 * plain allocation, what malloc-backed callers expect) works.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>

/* Mirror the POSIX constants — wasi-libc does not provide <sys/mman.h>. */
#define WB_PROT_READ   0x1
#define WB_PROT_WRITE  0x2

#define WB_MAP_SHARED    0x01
#define WB_MAP_PRIVATE   0x02
#define WB_MAP_ANONYMOUS 0x20

#define WB_MAP_FAILED ((void *) -1)

/* Track each live mapping so munmap/msync can flush MAP_SHARED back to the fd. */
struct wb_region {
    void   *addr;
    size_t  length;
    int     fd;
    int     prot;
    int     flags;
    off_t   offset;
    struct wb_region *next;
};

static struct wb_region *wb_regions = NULL;

static struct wb_region *wb_find(void *addr) {
    for (struct wb_region *r = wb_regions; r; r = r->next)
        if (r->addr == addr) return r;
    return NULL;
}

static int wb_flush(struct wb_region *r) {
    if (!(r->flags & WB_MAP_SHARED)) return 0;          /* PRIVATE: nothing to write */
    if (r->fd < 0 || !(r->prot & WB_PROT_WRITE)) return 0;
    size_t off = 0;
    while (off < r->length) {
        ssize_t n = pwrite(r->fd, (char *)r->addr + off,
                           r->length - off, r->offset + (off_t)off);
        if (n <= 0) { if (n < 0) return -1; break; }
        off += (size_t)n;
    }
    return 0;
}

void *__wrap_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    (void)addr;
    if (length == 0) { errno = EINVAL; return WB_MAP_FAILED; }

    void *buf = malloc(length);
    if (!buf) { errno = ENOMEM; return WB_MAP_FAILED; }

    if (flags & WB_MAP_ANONYMOUS) {
        memset(buf, 0, length);                          /* anon pages start zeroed */
    } else {
        memset(buf, 0, length);
        size_t off = 0;
        while (off < length) {
            ssize_t n = pread(fd, (char *)buf + off,
                              length - off, offset + (off_t)off);
            if (n < 0) { free(buf); return WB_MAP_FAILED; }
            if (n == 0) break;                           /* EOF: rest stays zeroed */
            off += (size_t)n;
        }
    }

    struct wb_region *r = malloc(sizeof *r);
    if (!r) { free(buf); errno = ENOMEM; return WB_MAP_FAILED; }
    r->addr = buf; r->length = length; r->fd = (flags & WB_MAP_ANONYMOUS) ? -1 : fd;
    r->prot = prot; r->flags = flags; r->offset = offset;
    r->next = wb_regions; wb_regions = r;
    return buf;
}

int __wrap_msync(void *addr, size_t length, int flags) {
    (void)length; (void)flags;
    struct wb_region *r = wb_find(addr);
    if (!r) { errno = EINVAL; return -1; }
    return wb_flush(r) == 0 ? 0 : -1;
}

int __wrap_munmap(void *addr, size_t length) {
    (void)length;
    struct wb_region *prev = NULL, *r = wb_regions;
    while (r && r->addr != addr) { prev = r; r = r->next; }
    if (!r) { errno = EINVAL; return -1; }
    int rc = wb_flush(r);
    if (prev) prev->next = r->next; else wb_regions = r->next;
    free(r->addr);
    free(r);
    return rc == 0 ? 0 : -1;
}
