#ifndef _SYS_MMAN_H
#define _SYS_MMAN_H

#include <sys/types.h>

extern void *mmap(void *, size_t, int, int, int, off_t);
extern int munmap(void *, size_t);
extern int msync(void *, size_t, int);
extern int mprotect(void *, size_t, int);

#define PROT_READ   0x1
#define PROT_WRITE  0x2
#define PROT_EXEC   0x4
#define PROT_NONE   0x0

#define MAP_SHARED    0x1
#define MAP_PRIVATE   0x2
#define MAP_FIXED     0x10
#define MAP_ANONYMOUS 0x1000
#define MAP_ANON      MAP_ANONYMOUS
#define MAP_FAILED    ((void *)-1)

#define MS_ASYNC  0x1
#define MS_SYNC   0x2
#define MS_INVALIDATE 0x4

#endif /* _SYS_MMAN_H */
