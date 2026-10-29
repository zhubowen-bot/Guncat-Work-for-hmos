// common/intercept.h — the two ways the same shim source gets "called"
#ifndef INTERCEPT_H
#define INTERCEPT_H

#if defined(INT_WARP)
/* Link-time interception: -Wl,--wrap=<name> redirects the call site to __wrap_<name>,
   and the original function is exposed as __real_<name> (in the same link, just take its address) */
#  define IEC_EXPORT(name) __wrap_##name
#  define IEC_REAL(ptr, name) ((ptr) != NULL ? (ptr) : ((ptr) = (__typeof__(ptr))__real_##name))
#elif defined(INT_PRELOAD)
/* Load-time interception: define a symbol with the same name directly, and locate the original
   with dlsym(RTLD_NEXT). RTLD_NEXT needs _GNU_SOURCE (-D_GNU_SOURCE is already added in the Makefile) */
#  include <dlfcn.h>
#  define IEC_EXPORT(name) name
#  define IEC_REAL(ptr, name) ((ptr) != NULL ? (ptr) : ((ptr) = (__typeof__(ptr))dlsym(RTLD_NEXT, #name)))
#else
#  error "Either INT_WARP or INT_PRELOAD must be defined!"
#endif

#endif /* INTERCEPT_H */
