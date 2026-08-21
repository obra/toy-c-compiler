/* Minimal malloc.h for our C compiler */
#ifndef _MALLOC_H
#define _MALLOC_H

#include <stddef.h>

typedef struct _malloc_zone_t malloc_zone_t;

struct _malloc_zone_t {
    void *reserved1;
    void *reserved2;
    size_t (*size)(struct _malloc_zone_t *, const void *);
    void *(*malloc)(struct _malloc_zone_t *, size_t);
    void *(*calloc)(struct _malloc_zone_t *, size_t, size_t);
    void *(*valloc)(struct _malloc_zone_t *, size_t);
    void (*free)(struct _malloc_zone_t *, void *);
    void *(*realloc)(struct _malloc_zone_t *, void *, size_t);
    void (*destroy)(struct _malloc_zone_t *);
    const char *zone_name;
};

malloc_zone_t *malloc_default_zone(void);
void *malloc_zone_malloc(malloc_zone_t *zone, size_t size);
void malloc_zone_free(malloc_zone_t *zone, void *ptr);
void *malloc_zone_realloc(malloc_zone_t *zone, void *ptr, size_t size);

#endif /* _MALLOC_H */
