/* Minimal stdlib.h for our C compiler */
#ifndef _STDLIB_H
#define _STDLIB_H

void *malloc(unsigned long size);
void free(void *ptr);
void *calloc(unsigned long nmemb, unsigned long size);
void *realloc(void *ptr, unsigned long size);

void exit(int status);
void abort(void);
int atexit(void (*func)(void));

int abs(int n);
long labs(long n);

int atoi(const char *nptr);
long atol(const char *nptr);
long strtol(const char *nptr, char **endptr, int base);
unsigned long strtoul(const char *nptr, char **endptr, int base);
double strtod(const char *nptr, char **endptr);

int rand(void);
void srand(unsigned int seed);

void qsort(void *base, unsigned long nmemb, unsigned long size,
           int (*compar)(const void *, const void *));

#endif /* _STDLIB_H */
