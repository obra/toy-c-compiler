#ifndef _SYS_TIME_H
#define _SYS_TIME_H

#include <sys/types.h>
#include <time.h>

struct timeval {
    long tv_sec;
    long tv_usec;
};

struct timezone {
    int tz_minuteswest;
    int tz_dsttime;
};

extern int gettimeofday(struct timeval *, struct timezone *);
extern int settimeofday(const struct timeval *, const struct timezone *);
extern int select(int, void *, void *, void *, struct timeval *);

#endif /* _SYS_TIME_H */
