/*
 * X11/extensions/Xrandr.h — X11 桩头（见 X11/Xlib.h 顶部说明）
 *
 * lib-x11.m4 的 AC_CHECK_HEADERS 探针之一。
 */
#ifndef BSH_STUB_X11_EXT_XRANDR_H
#define BSH_STUB_X11_EXT_XRANDR_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrender.h>

#define RANDR_NAME "RANDR"
#define RANDR_MAJOR 1
#define RANDR_MINOR 6

#define RR_Connected        0
#define RR_Disconnected     1
#define RR_UnknownConnection 2

#define RR_Rotate_0     1
#define RR_Rotate_90    2
#define RR_Rotate_180   4
#define RR_Rotate_270   8

#define RR_Reflect_X    16
#define RR_Reflect_Y    32

#define RR_NotifyMask   (1L << 0)

typedef XID RROutput;
typedef XID RRCrtc;
typedef XID RRMode;
typedef unsigned long RRScreenSize;

typedef struct {
    int width, height;
    int mwidth, mheight;
} XRRScreenSize;

typedef struct {
    Time timestamp;
    Time config_timestamp;
    int nsize;
    XRRScreenSize *sizes;
    int mwidth, mheight;
    int mm_width, mm_height;
} XRRScreenConfiguration;

extern XRRScreenConfiguration *XRRGetScreenInfo(Display *dpy, Window window);
extern int   XRRConfigRotations(XRRScreenConfiguration *config, unsigned int *current_rotation);
extern Window XRRRootToWindow(Display *dpy, Window root, int screen);
extern void  XRRFreeScreenConfigInfo(XRRScreenConfiguration *config);
extern int   XRRQueryExtension(Display *dpy, int *event_basep, int *error_basep);

#endif /* BSH_STUB_X11_EXT_XRANDR_H */
