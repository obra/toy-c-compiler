/* stdarg.h - variadic argument support for our C compiler */
#ifndef _STDARG_H
#define _STDARG_H

/* va_list is a pointer to the variadic args buffer. */
typedef char *va_list[1];

/* va_start: call builtin that saves arg registers and returns pointer */
extern void *__builtin_va_start(void);
#define va_start(ap, last) (*(ap) = (char*)__builtin_va_start())

/* va_arg: load 8 bytes from current position and advance by 8. */
#define va_arg(ap, type) (*(type*)((*(ap) += 8) - 8))

#define va_end(ap) ((void)0)
#define va_copy(dest, src) (*(dest) = *(src))

#endif /* _STDARG_H */
