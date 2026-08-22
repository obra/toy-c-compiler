#ifndef _DLFCN_H
#define _DLFCN_H

extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int dlclose(void *);
extern char *dlerror(void);

#define RTLD_LAZY   1
#define RTLD_NOW    2
#define RTLD_GLOBAL 0x100
#define RTLD_LOCAL  0
#define RTLD_DEFAULT ((void *)0)
#define RTLD_NEXT    ((void *)-1)

#endif /* _DLFCN_H */
