#ifndef _SYS_STAT_H
#define _SYS_STAT_H

#include <sys/types.h>
#include <time.h>   /* for struct timespec used in struct stat */

extern int stat(const char *, struct stat *);
extern int fstat(int, struct stat *);
extern int lstat(const char *, struct stat *);
extern int chmod(const char *, mode_t);
extern int fchmod(int, mode_t);
extern int mkdir(const char *, mode_t);
extern int mkfifo(const char *, mode_t);
extern mode_t umask(mode_t);

struct stat {
    dev_t           st_dev;         /* [0]  ID of device containing file */
    mode_t          st_mode;        /* [4]  File mode */
    nlink_t         st_nlink;       /* [6]  Number of hard links */
    ino_t           st_ino;         /* [8]  File serial number */
    uid_t           st_uid;         /* [16] User ID of file */
    gid_t           st_gid;         /* [20] Group ID of file */
    dev_t           st_rdev;        /* [24] Device ID (if special file) */
    struct timespec st_atimespec;   /* [32] Last access time (ts: 16 bytes) */
    struct timespec st_mtimespec;   /* [48] Last modification time */
    struct timespec st_ctimespec;   /* [64] Last status change time */
    struct timespec st_birthtimespec; /* [80] Creation time */
    off_t           st_size;        /* [96] File size in bytes */
    blkcnt_t        st_blocks;      /* [104] Blocks allocated */
    blksize_t       st_blksize;     /* [112] Optimal I/O block size */
    unsigned int    st_flags;       /* [116] User defined flags */
    unsigned int    st_gen;         /* [120] File generation number */
    int             st_lspare;      /* [124] Reserved */
    long long       st_qspare[2];   /* [128] Reserved */
    /* Total: 144 bytes */
};

#define S_IFMT   0170000
#define S_IFDIR  0040000
#define S_IFCHR  0020000
#define S_IFBLK  0060000
#define S_IFREG  0100000
#define S_IFIFO  0010000
#define S_IFLNK  0120000
#define S_IFSOCK 0140000
#define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m)  (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)  (((m) & S_IFMT) == S_IFBLK)
#define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
#define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO)
#define S_ISLNK(m)  (((m) & S_IFMT) == S_IFLNK)
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)

/* Backward-compatible time field aliases (match macOS system headers) */
#define st_atime    st_atimespec.tv_sec
#define st_mtime    st_mtimespec.tv_sec
#define st_ctime    st_ctimespec.tv_sec
#define st_birthtime st_birthtimespec.tv_sec

#define S_ISUID 04000
#define S_ISGID 02000
#define S_ISVTX 01000

#define S_IRWXU 00700
#define S_IRUSR 00400
#define S_IWUSR 00200
#define S_IXUSR 00100
#define S_IRWXG 00070
#define S_IRGRP 00040
#define S_IWGRP 00020
#define S_IXGRP 00010
#define S_IRWXO 00007
#define S_IROTH 00004
#define S_IWOTH 00002
#define S_IXOTH 00001

#endif /* _SYS_STAT_H */
