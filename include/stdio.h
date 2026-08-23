/* Minimal stdio.h for our C compiler */
#ifndef _STDIO_H
#define _STDIO_H

#include <stddef.h>

#define FILENAME_MAX 1024
#define FOPEN_MAX 20
#define BUFSIZ 1024
#define EOF (-1)

typedef struct __sFILE FILE;

/* On macOS, stdin/stdout/stderr are macros that expand to __stdinp etc. */
extern FILE *__stdinp;
extern FILE *__stdoutp;
extern FILE *__stderrp;
#define stdin __stdinp
#define stdout __stdoutp
#define stderr __stderrp

int printf(const char *format, ...);
int fprintf(FILE *stream, const char *format, ...);
int sprintf(char *str, const char *format, ...);
int snprintf(char *str, size_t size, const char *format, ...);
int scanf(const char *format, ...);
int fscanf(FILE *stream, const char *format, ...);
int sscanf(const char *str, const char *format, ...);

int vprintf(const char *format, __builtin_va_list ap);
int vfprintf(FILE *stream, const char *format, __builtin_va_list ap);
int vsprintf(char *str, const char *format, __builtin_va_list ap);
int vsnprintf(char *str, size_t size, const char *format, __builtin_va_list ap);

int puts(const char *s);
int putchar(int c);
int fputs(const char *s, FILE *stream);
int fputc(int c, FILE *stream);

FILE *fopen(const char *path, const char *mode);
int fclose(FILE *fp);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fgetc(FILE *stream);
int getc(FILE *stream);
char *fgets(char *s, int size, FILE *stream);
int fflush(FILE *stream);
int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);

#endif /* _STDIO_H */
