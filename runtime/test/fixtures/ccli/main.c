/*
 * mmap round-trip fixture (C/wasi CLI).
 *
 * Usage: ccli <path>
 *   - mmap()s <path> MAP_SHARED, PROT_READ|PROT_WRITE
 *   - prints the first byte it read THROUGH the pointer (proves read-through-mmap)
 *   - uppercases every lowercase ASCII byte IN the mapping
 *   - msync()+munmap() (proves write-back-through-mmap to the host file)
 *
 * Built through the runtime's C/wasi path, the mmap symbol resolves to the
 * shim (build/shims/mmap_shim.c). Run under wasmtime with a preopen so the
 * guest can open the host file.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>

/* Declared here (no <sys/mman.h> in wasi-libc); resolved by the shim. */
extern void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
extern int   msync(void *addr, size_t length, int flags);
extern int   munmap(void *addr, size_t length);

#define PROT_READ   0x1
#define PROT_WRITE  0x2
#define MAP_SHARED  0x01
#define MS_SYNC     0x4

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <path>\n", argv[0]); return 2; }

    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    off_t len = lseek(fd, 0, SEEK_END);
    if (len <= 0) { fprintf(stderr, "empty/seek fail\n"); close(fd); return 1; }
    lseek(fd, 0, SEEK_SET);

    char *m = mmap(NULL, (size_t)len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == (void *)-1) { fprintf(stderr, "mmap unsupported/failed\n"); close(fd); return 1; }

    printf("read-through: %c\n", m[0]);            /* proves pread populated the map */

    for (off_t i = 0; i < len; i++)
        if (m[i] >= 'a' && m[i] <= 'z') m[i] -= 32; /* mutate through the pointer */

    if (msync(m, (size_t)len, MS_SYNC) != 0) { perror("msync"); }
    if (munmap(m, (size_t)len) != 0) { perror("munmap"); close(fd); return 1; }
    close(fd);
    printf("ok\n");
    return 0;
}
