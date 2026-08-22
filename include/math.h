#ifndef _MATH_H
#define _MATH_H

extern double sqrt(double);
extern double pow(double, double);
extern double exp(double);
extern double log(double);
extern double log10(double);
extern double sin(double);
extern double cos(double);
extern double tan(double);
extern double asin(double);
extern double acos(double);
extern double atan(double);
extern double atan2(double, double);
extern double floor(double);
extern double ceil(double);
extern double fabs(double);
extern double fmod(double, double);
extern double ldexp(double, int);
extern double frexp(double, int *);
extern double modf(double, double *);

#define HUGE_VAL ((double)1e308)
#define INFINITY ((double)1e308)
#define NAN ((double)0.0/0.0)

#define M_PI 3.14159265358979323846
#define M_E  2.71828182845904523536

#endif /* _MATH_H */
