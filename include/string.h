/* Minimal string.h for our C compiler */
#ifndef _STRING_H
#define _STRING_H

unsigned long strlen(const char *s);
int strcmp(const char *s1, const char *s2);
int strncmp(const char *s1, const char *s2, unsigned long n);
char *strcpy(char *dest, const char *src);
char *strncpy(char *dest, const char *src, unsigned long n);
char *strcat(char *dest, const char *src);
char *strncat(char *dest, const char *src, unsigned long n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);
unsigned long strspn(const char *s, const char *accept);
unsigned long strcspn(const char *s, const char *reject);
char *strpbrk(const char *s, const char *accept);
char *strerror(int errnum);
char *strdup(const char *s);
int strcasecmp(const char *s1, const char *s2);
int strncasecmp(const char *s1, const char *s2, unsigned long n);
unsigned long strlcpy(char *dst, const char *src, unsigned long size);
unsigned long strlcat(char *dst, const char *src, unsigned long size);

void *memcpy(void *dest, const void *src, unsigned long n);
void *memmove(void *dest, const void *src, unsigned long n);
void *memset(void *s, int c, unsigned long n);
int memcmp(const void *s1, const void *s2, unsigned long n);
void *memchr(const void *s, int c, unsigned long n);

/* GNU extension: mempcpy returns dest + n (pointer to byte after last written) */
void *mempcpy(void *dest, const void *src, unsigned long n);

#endif /* _STRING_H */
