#ifndef _SYS_FILE_H
#define _SYS_FILE_H

#include <sys/types.h>

extern int flock(int, int);

#define LOCK_SH 1
#define LOCK_EX 2
#define LOCK_NB 4
#define LOCK_UN 8

#endif /* _SYS_FILE_H */
