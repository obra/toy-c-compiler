#ifndef _MALLOC_MALLOC_H
#define _MALLOC_MALLOC_H

#include <sys/types.h>

typedef struct _malloc_zone_t {
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
    unsigned batch_malloc;
    unsigned batch_free;
    void *introspect;
    size_t requested_size;
} malloc_zone_t;

extern malloc_zone_t *malloc_default_zone(void);
extern malloc_zone_t *malloc_create_zone(vm_offset_t, unsigned);
extern void malloc_set_zone_name(malloc_zone_t *, const char *);
extern size_t malloc_size(const void *);
extern void *malloc_zone_malloc(malloc_zone_t *, size_t);
extern void *malloc_zone_calloc(malloc_zone_t *, size_t, size_t);
extern void *malloc_zone_valloc(malloc_zone_t *, size_t);
extern void *malloc_zone_realloc(malloc_zone_t *, void *, size_t);
extern void malloc_zone_free(malloc_zone_t *, void *);

typedef unsigned long vm_offset_t;

#endif /* _MALLOC_MALLOC_H */
