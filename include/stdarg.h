/* Minimal stdarg.h for our C compiler */
#ifndef _STDARG_H
#define _STDARG_H

typedef struct {
    char *gp_offset;
    char *fp_offset;
    void *overflow_arg_area;
    void *reg_save_area;
} __va_list_struct;

typedef __va_list_struct va_list[1];

/* For our compiler, we don't fully support varargs in user code.
   These macros are simplified stubs. */
#define va_start(ap, last) ((void)0)
#define va_end(ap) ((void)0)
#define va_arg(ap, type) ((type)0)
#define va_copy(dest, src) ((dest) = (src))

#endif /* _STDARG_H */
