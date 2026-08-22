#ifndef _UNISTD_H
#define _UNISTD_H

#include <sys/types.h>
#include <sys/time.h>

extern int close(int);
extern ssize_t read(int, void *, size_t);
extern ssize_t write(int, const void *, size_t);
extern ssize_t pread(int, void *, size_t, off_t);
extern ssize_t pwrite(int, const void *, size_t, off_t);
extern int ftruncate(int, off_t);
extern int fsync(int);
extern int fdatasync(int);
extern off_t lseek(int, off_t, int);
extern int unlink(const char *);
extern int access(const char *, int);
extern int fcntl(int, int, ...);
extern int dup(int);
extern int dup2(int, int);
extern int pipe(int[2]);
extern pid_t fork(void);
extern int execve(const char *, char *const[], char *const[]);
extern pid_t getpid(void);
extern pid_t getppid(void);
extern char *getcwd(char *, size_t);
extern int chdir(const char *);
extern int rmdir(const char *);
extern int chown(const char *, uid_t, gid_t);
extern int fchown(int, uid_t, gid_t);
extern int link(const char *, const char *);
extern int symlink(const char *, const char *);
extern ssize_t readlink(const char *, char *, size_t);
extern int truncate(const char *, off_t);
extern int gethostname(char *, size_t);
extern unsigned int sleep(unsigned int);
extern int usleep(unsigned int);
extern int pause(void);
extern int isatty(int);
extern pid_t setsid(void);
extern pid_t getpgrp(void);
extern int setpgid(pid_t, pid_t);
extern uid_t geteuid(void);
extern uid_t getuid(void);
extern gid_t getegid(void);
extern gid_t getgid(void);
extern int setuid(uid_t);
extern int setgid(gid_t);
extern int seteuid(uid_t);
extern int setegid(gid_t);
extern int chroot(const char *);
extern int getpagesize(void);
extern int utimes(const char *, const struct timeval *);
extern int utime(const char *, const void *);
extern char *getenv(const char *);
extern int putenv(char *);
extern int setenv(const char *, const char *, int);
extern int unsetenv(const char *);
extern long random(void);
extern void srandom(unsigned int);
extern void srandomdev(void);
extern int nanosleep(const void *, void *);
extern unsigned int alarm(unsigned int);
extern int rename(const char *, const char *);
extern int futimes(int, const void *);

#define R_OK 4
#define W_OK 2
#define X_OK 1
#define F_OK 0

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define _SC_PAGESIZE 30
#define _SC_PAGE_SIZE 30
extern long sysconf(int);

#define _PC_NAME_MAX 1
extern long pathconf(const char *, int);

#endif /* _UNISTD_H */
