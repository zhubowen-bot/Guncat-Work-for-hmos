/*
 * X11/XKBlib.h — X11 桩头的一部分（见 X11/Xlib.h 顶部说明）
 */
#ifndef BSH_STUB_X11_XKBLIB_H
#define BSH_STUB_X11_XKBLIB_H

#include <X11/Xlib.h>
#include <X11/keysym.h>

#define XkbUseCoreKbd   0x0100
#define XkbUseCorePtr   0x0200

#define XkbKeycodeToKeysym(dpy, kc, grp, lvl) 0L

extern int XkbQueryExtension(Display *dpy, int *opcode_rtrn, int *event_rtrn,
                             int *error_rtrn, int *major_rtrn, int *minor_rtrn);
extern int XkbGetMap(Display *dpy, unsigned int which, unsigned int device_spec);
extern int XkbGetNames(Display *dpy, unsigned int which, unsigned int device_spec);

#endif /* BSH_STUB_X11_XKBLIB_H */
