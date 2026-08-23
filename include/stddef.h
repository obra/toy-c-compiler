/* Minimal stddef.h for our C compiler */
#ifndef _STDDEF_H
#define _STDDEF_H

typedef unsigned long size_t;
typedef signed long ptrdiff_t;

#ifndef _WCHAR_T
#define _WCHAR_T
typedef int wchar_t;
#endif

#ifndef NULL
#define NULL ((void*)0)
#endif

#define offsetof(type, member) ((size_t)(&((type*)0)->member))

/* GCC-compatible built-in functions */
extern void __sync_synchronize(void);

#endif /* _STDDEF_H */
