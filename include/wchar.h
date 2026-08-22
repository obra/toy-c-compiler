#ifndef _WCHAR_H
#define _WCHAR_H

typedef int wchar_t;

#ifndef NULL
#define NULL ((void*)0)
#endif

/* Wide character I/O functions */
int wprintf(const wchar_t *format, ...);
int wscanf(const wchar_t *format, ...);
int fwprintf(void *stream, const wchar_t *format, ...);
int fwscanf(void *stream, const wchar_t *format, ...);
int swprintf(wchar_t *str, unsigned long size, const wchar_t *format, ...);
int swscanf(const wchar_t *str, const wchar_t *format, ...);

/* Wide character string functions */
unsigned long wcslen(const wchar_t *s);
wchar_t *wcscpy(wchar_t *dest, const wchar_t *src);
wchar_t *wcsncpy(wchar_t *dest, const wchar_t *src, unsigned long n);
int wcscmp(const wchar_t *s1, const wchar_t *s2);
int wcsncmp(const wchar_t *s1, const wchar_t *s2, unsigned long n);
wchar_t *wcscat(wchar_t *dest, const wchar_t *src);
wchar_t *wcsncat(wchar_t *dest, const wchar_t *src, unsigned long n);
wchar_t *wcschr(const wchar_t *s, wchar_t c);
wchar_t *wcsrchr(const wchar_t *s, wchar_t c);

/* Wide character classification (from wctype.h) */
int iswalpha(wchar_t c);
int iswdigit(wchar_t c);
int iswspace(wchar_t c);
int iswupper(wchar_t c);
int iswlower(wchar_t c);
int iswalnum(wchar_t c);
int iswxdigit(wchar_t c);
int iswprint(wchar_t c);
int iswgraph(wchar_t c);
int iswpunct(wchar_t c);
int iswcntrl(wchar_t c);

wchar_t towupper(wchar_t c);
wchar_t towlower(wchar_t c);

/* Wide character I/O */
wchar_t *fgetws(wchar_t *s, int n, void *stream);
int fputws(const wchar_t *s, void *stream);

/* stdarg for wide functions */
#include <stdarg.h>

/* mbstate_t and conversion functions */
typedef int mbstate_t;
unsigned long mbrtowc(wchar_t *pwc, const char *s, unsigned long n, mbstate_t *ps);
unsigned long wcrtomb(char *s, wchar_t wc, mbstate_t *ps);
int mbsinit(const mbstate_t *ps);

/* WEOF */
typedef int wint_t;
#define WEOF ((wint_t)-1)

#endif
