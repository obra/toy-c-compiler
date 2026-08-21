/* Minimal time.h for our C compiler */
#ifndef _TIME_H
#define _TIME_H

#include <stddef.h>

typedef long time_t;
typedef long suseconds_t;
typedef long clock_t;

struct tm {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
    long tm_gmtoff;
    char *tm_zone;
};

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

struct timeval {
    time_t tv_sec;
    suseconds_t tv_usec;
};

struct timezone {
    int tz_minuteswest;
    int tz_dsttime;
};

#define CLOCKS_PER_SEC 1000000

time_t time(time_t *tloc);
struct tm *localtime(const time_t *timer);
struct tm *gmtime(const time_t *timer);
time_t mktime(struct tm *tm);
size_t strftime(char *s, size_t max, const char *format, const struct tm *tm);
char *strptime(const char *s, const char *format, struct tm *tm);
int clock_gettime(int clk_id, struct timespec *tp);
int gettimeofday(struct timeval *tv, struct timezone *tz);

#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 6

#endif /* _TIME_H */
