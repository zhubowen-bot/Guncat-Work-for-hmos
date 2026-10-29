/*
 * X11/extensions/shape.h — X11 桩头（见 X11/Xlib.h 顶部说明）
 *
 * lib-x11.m4 的 AC_CHECK_HEADERS 探针之一。
 */
#ifndef BSH_STUB_X11_EXT_SHAPE_H
#define BSH_STUB_X11_EXT_SHAPE_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define ShapeSet            0
#define ShapeUnion          1
#define ShapeIntersect      2
#define ShapeSubtract       3
#define ShapeInvert         4

#define ShapeBounding       0
#define ShapeClip           1
#define ShapeInput          2

#define ShapeNotifyMask     (1L << 0)
#define ShapeNotify         0

#define ShapeNumberEvents   (ShapeNotify + 1)

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    int kind;
    int x, y;
    int width, height;
    Time time;
    Bool shaped;
} XShapeEvent;

extern void XShapeCombineMask(Display *display, Window dest, int destKind,
                              int xOff, int yOff, Pixmap src, int op);

#endif /* BSH_STUB_X11_EXT_SHAPE_H */
