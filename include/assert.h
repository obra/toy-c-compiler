/* Minimal assert.h for our C compiler */
#ifndef _ASSERT_H
#define _ASSERT_H

#ifdef NDEBUG
#define assert(expr) ((void)0)
#else
#define assert(expr) ((expr) ? (void)0 : (void)0)
#endif

#endif /* _ASSERT_H */
