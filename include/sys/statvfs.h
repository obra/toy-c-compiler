#ifndef _SYS_STATVFS_H
#define _SYS_STATVFS_H

#include <sys/types.h>

struct statvfs {
    unsigned long f_bsize;
    unsigned long f_frsize;
    unsigned long long f_blocks;
    unsigned long long f_bfree;
    unsigned long long f_bavail;
    unsigned long long f_files;
    unsigned long long f_ffree;
    unsigned long f_favail;
    unsigned long f_fsid;
    unsigned long f_flag;
    unsigned long f_namemax;
};

#endif /* _SYS_STATVFS_H */
