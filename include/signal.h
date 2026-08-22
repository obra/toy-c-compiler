/* Minimal signal.h for our C compiler */
#ifndef _SIGNAL_H
#define _SIGNAL_H

#define SIGABRT 6
#define SIGFPE 8
#define SIGILL 4
#define SIGINT 2
#define SIGSEGV 11
#define SIGTERM 15
#define SIGHUP 1
#define SIGKILL 9
#define SIGPIPE 13
#define SIGQUIT 3
#define SIGUSR1 16
#define SIGUSR2 17

#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)
#define SIG_ERR ((void (*)(int))-1)

typedef int sig_atomic_t;

void (*signal(int sig, void (*func)(int)))(int);
int raise(int sig);

#endif /* _SIGNAL_H */
