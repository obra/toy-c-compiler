/* Minimal setjmp.h for our C compiler */
#ifndef _SETJMP_H
#define _SETJMP_H

/* On ARM64, jmp_buf is an array large enough to hold all callee-saved registers */
typedef long jmp_buf[32];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

#endif /* _SETJMP_H */
