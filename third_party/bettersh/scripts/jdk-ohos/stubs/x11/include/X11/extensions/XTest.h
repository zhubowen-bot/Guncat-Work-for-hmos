/*
 * X11/extensions/XTest.h — X11 桩头（见 X11/Xlib.h 顶部说明）
 *
 * lib-x11.m4 的 AC_CHECK_HEADERS 探针之一。
 */
#ifndef BSH_STUB_X11_EXT_XTEST_H
#define BSH_STUB_X11_EXT_XTEST_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define XTestNumberEvents   0
#define XTestNumberErrors   0

#define XTestReqCurrentCursor  1
#define XTestReqGrabControl    3

/* 上游这里是一串 "XTestFakeKeyEvent 0" 之类的请求号宏，会和下面的函数名撞车；
 * headless 构建不链接 XTest，数值不重要，这里换成不冲突的名字。 */
#define XTestReqFakeKeyEvent         0
#define XTestReqFakeButtonEvent      1
#define XTestReqFakeMotionEvent      2
#define XTestReqFakeRelativeMotionEvent 3
#define XTestReqFakeDeviceKeyEvent   4
#define XTestReqFakeDeviceButtonEvent 5
#define XTestReqFakeProximityEvent   6
#define XTestReqFakeDeviceMotionEvent 7

extern int XTestQueryExtension(Display *display, int *event_base, int *error_base,
                               int *major, int *minor);
extern int XTestFakeKeyEvent(Display *display, unsigned int keycode, Bool is_press, unsigned long delay);
extern int XTestFakeButtonEvent(Display *display, unsigned int button, Bool is_press, unsigned long delay);
extern int XTestFakeMotionEvent(Display *display, int screen_number, int x, int y, unsigned long delay);
extern int XTestGrabControl(Display *display, Bool impervious);

#endif /* BSH_STUB_X11_EXT_XTEST_H */
