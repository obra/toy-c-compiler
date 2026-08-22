#ifndef _FCNTL_H
#define _FCNTL_H

#include <sys/types.h>
#include <unistd.h>

extern int open(const char *, int, ...);
extern int creat(const char *, mode_t);
extern int fsctl(const char *, unsigned long, void *, int);

#define O_RDONLY  0x0000
#define O_WRONLY  0x0001
#define O_RDWR    0x0002
#define O_ACCMODE 0x0003
#define O_NONBLOCK 0x0004
#define O_APPEND  0x0008
#define O_CREAT   0x0200
#define O_TRUNC   0x0400
#define O_EXCL    0x0800
#define O_NOCTTY  0x20000
#define O_SYNC    0x0080
#define O_DSYNC   0x400000
#define O_NDELAY  O_NONBLOCK

#define F_DUPFD    0
#define F_GETFD    1
#define F_SETFD    2
#define F_GETFL    3
#define F_SETFL    4
#define F_GETLK    7
#define F_SETLK    8
#define F_SETLKW   9

#define FD_CLOEXEC 1

#define F_RDLCK 1
#define F_UNLCK 2
#define F_WRLCK 3

struct flock {
    short l_type;
    short l_whence;
    off_t l_start;
    off_t l_len;
    pid_t l_pid;
};

#endif /* _FCNTL_H */
