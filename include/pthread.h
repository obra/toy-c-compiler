/* Minimal pthread.h for our C compiler */
#ifndef _PTHREAD_H
#define _PTHREAD_H

#include <stddef.h>

typedef unsigned long pthread_t;
typedef unsigned long pthread_key_t;

typedef struct {
    long __sig;
    char __opaque[56];
} pthread_attr_t;

typedef struct {
    long __sig;
    char __opaque[56];
} pthread_mutexattr_t;

typedef struct {
    long __sig;
    char __opaque[56];
} pthread_mutex_t;

typedef struct {
    long __sig;
    char __opaque[40];
} pthread_cond_t;

typedef struct {
    long __sig;
    char __opaque[24];
} pthread_condattr_t;

typedef struct {
    char __opaque[8];
} pthread_once_t;

#define PTHREAD_MUTEX_INITIALIZER { 0x32AAABA7, {0} }
#define PTHREAD_COND_INITIALIZER { 0x3CB0B1BB, {0} }
#define PTHREAD_ONCE_INIT { 0x30D1BB1 }

#define PTHREAD_MUTEX_RECURSIVE 2

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg);
int pthread_join(pthread_t thread, void **retval);
pthread_t pthread_self(void);

int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr);
int pthread_mutex_destroy(pthread_mutex_t *mutex);
int pthread_mutex_lock(pthread_mutex_t *mutex);
int pthread_mutex_trylock(pthread_mutex_t *mutex);
int pthread_mutex_unlock(pthread_mutex_t *mutex);

int pthread_mutexattr_init(pthread_mutexattr_t *attr);
int pthread_mutexattr_destroy(pthread_mutexattr_t *attr);
int pthread_mutexattr_settype(pthread_mutexattr_t *attr, int type);

int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int pthread_cond_signal(pthread_cond_t *cond);
int pthread_cond_broadcast(pthread_cond_t *cond);

int pthread_key_create(pthread_key_t *key, void (*destructor)(void *));
int pthread_key_delete(pthread_key_t key);
void *pthread_getspecific(pthread_key_t key);
int pthread_setspecific(pthread_key_t key, const void *value);

int pthread_once(pthread_once_t *once, void (*init)(void));

#endif /* _PTHREAD_H */
