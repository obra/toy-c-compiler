#ifndef _SYS_SYSCTL_H
#define _SYS_SYSCTL_H

#include <sys/types.h>

extern int sysctlbyname(const char *, void *, size_t *, const void *, size_t);
extern int sysctl(int *, unsigned int, void *, size_t *, void *, size_t);

#endif /* _SYS_SYSCTL_H */
