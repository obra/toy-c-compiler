/* Stubs for undefined functions referenced by GCC torture tests.
 * These are typically dead-code functions that the compiler should optimize away,
 * or test harness functions that are never actually called at runtime.
 * Use weak symbols so they don't conflict with functions defined in the test. */

extern void abort(void);

/* Common test helper functions */
__attribute__((weak)) void link_error(void) { abort(); }
__attribute__((weak)) void f(void) { abort(); }

/* alias-2/3/4: b and d are data arrays aliased to a/c via __attribute__((alias)).
 * Since we don't support the alias attribute, provide weak data stubs. */
__attribute__((weak)) int b[10];
__attribute__((weak)) int d[10];

/* pr105777/pr30314/pr98304-2: bar, foo, baz, etc. */
__attribute__((weak)) void bar(void) { abort(); }
__attribute__((weak)) void foo(void) { abort(); }
__attribute__((weak)) void baz(void) { abort(); }
__attribute__((weak)) void qux(void) { abort(); }
__attribute__((weak)) void quux(void) { abort(); }
__attribute__((weak)) void corge(void) { abort(); }
__attribute__((weak)) void grault(void) { abort(); }
__attribute__((weak)) void garply(void) { abort(); }
__attribute__((weak)) void waldo(void) { abort(); }
__attribute__((weak)) void thud(void) { abort(); }

/* pr91597: C is a function */
__attribute__((weak)) void C(void) { abort(); }

/* string-opt-18: mempcpy - GNU extension, returns dest + n */
__attribute__((weak)) void *mempcpy(void *dest, const void *src, unsigned long n) {
    char *d = (char *)dest;
    const char *s = (const char *)src;
    for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    return d + n;
}

/* builtin-prefetch-2: gx is a global function */
__attribute__((weak)) void gx(void) { abort(); }
