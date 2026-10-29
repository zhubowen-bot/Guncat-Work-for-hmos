/*
 * X11/Intrinsic.h — X11 桩头（见 X11/Xlib.h 顶部说明）
 *
 * lib-x11.m4 的 AC_CHECK_HEADERS 探针之一。Xt/Intrinsics 只在 libawt_xawt 里用，
 * headless 配置下不构建，所以这里只保留"能编过"所需的最小面。
 */
#ifndef BSH_STUB_X11_INTRINSIC_H
#define BSH_STUB_X11_INTRINSIC_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define XtSpecificationRelease 6

typedef char *String;
typedef char *XtPointer;
typedef long  XtArgVal;
typedef XID   Widget;
typedef XID   XtAppContext;
typedef XID   Cardinal;
typedef XID   Dimension;
typedef XID   Position;
typedef XID   ArgList;

typedef struct {
    String name;
    XtArgVal value;
} Arg;

typedef struct _WidgetClassRec *WidgetClass;
typedef struct _WidgetRec      *WidgetRec;

typedef void (*XtProc)(void);
typedef void (*XtActionProc)(void);
typedef void (*XtEventHandler)(void);

#define XtNumber(arr) ((Cardinal)(sizeof(arr) / sizeof(arr[0])))

#define XtNwidth  "width"
#define XtNheight "height"
#define XtNx      "x"
#define XtNy      "y"

#endif /* BSH_STUB_X11_INTRINSIC_H */
