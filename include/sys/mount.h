#ifndef _SYS_MOUNT_H
#define _SYS_MOUNT_H

#include <sys/types.h>

struct statfs {
    unsigned long f_bsize;
    unsigned long f_iosize;
    unsigned long long f_blocks;
    unsigned long long f_bfree;
    unsigned long long f_bavail;
    unsigned long long f_files;
    unsigned long long f_ffree;
    unsigned long f_fsid;
    unsigned long f_owner;
    unsigned long f_type;
    unsigned long f_flags;
    unsigned long f_fssubtype;
    char f_fstypename[16];
    char f_mntonname[1024];
    char f_mntfromname[1024];
    unsigned long f_reserved[8];
};

extern int statfs(const char *, struct statfs *);
extern int fstatfs(int, struct statfs *);
extern int getmntinfo(struct statfs **, int);

#define MNT_RDONLY    0x1
#define MNT_NOSUID   0x10
#define MNT_NOEXEC   0x4
#define MNT_SYNCHRONOUS 0x2
#define MNT_NODEV    0x8
#define MNT_UNION    0x20
#define MNT_ASYNC    0x40
#define MNT_LOCAL    0x1000
#define MNT_QUOTA    0x2000
#define MNT_ROOTFS   0x4000
#define MNT_EXPORTED 0x10000

#endif /* _SYS_MOUNT_H */
