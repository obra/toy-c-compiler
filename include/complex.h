/* Minimal complex.h for our C compiler */
#ifndef _COMPLEX_H
#define _COMPLEX_H

/* C99 complex number support */
/* _Complex types are built into the compiler */

#define _Complex_I (__extension__ 1.0i)
#define I _Complex_I
#define _Imaginary_I (__extension__ 1.0i)

/* Complex math functions */
double creal(_Complex double z);
double cimag(_Complex double z);
_Complex double conj(_Complex double z);
_Complex double cabs(_Complex double z);
_Complex double csqrt(_Complex double z);
_Complex double cexp(_Complex double z);
_Complex double clog(_Complex double z);
_Complex double cpow(_Complex double z, _Complex double w);
_Complex double csin(_Complex double z);
_Complex double ccos(_Complex double z);
_Complex double ctan(_Complex double z);

float crealf(_Complex float z);
float cimagf(_Complex float z);

long double creall(_Complex long double z);
long double cimagl(_Complex long double z);

#endif /* _COMPLEX_H */
