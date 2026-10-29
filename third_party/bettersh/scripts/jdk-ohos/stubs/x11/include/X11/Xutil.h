/*
 * X11/Xutil.h — X11 桩头的一部分（见 X11/Xlib.h 顶部说明）
 */
#ifndef BSH_STUB_X11_XUTIL_H
#define BSH_STUB_X11_XUTIL_H

#include <X11/Xlib.h>

#define NoValue     0x0000
#define XValue      0x0001
#define YValue      0x0002
#define WidthValue  0x0004
#define HeightValue 0x0008
#define AllValues   0x000F
#define XNegative   0x0010
#define YNegative   0x0020
#define USPosition  (1L << 0)
#define USSize      (1L << 1)
#define PPosition   (1L << 2)
#define PSize       (1L << 3)
#define PMinSize    (1L << 4)
#define PMaxSize    (1L << 5)
#define PResizeInc  (1L << 6)
#define PAspect     (1L << 7)
#define PBaseSize   (1L << 8)
#define PWinGravity (1L << 9)
#define InputHint       (1L << 0)
#define StateHint       (1L << 1)
#define IconPixmapHint  (1L << 2)
#define IconWindowHint  (1L << 3)
#define IconPositionHint (1L << 4)
#define IconMaskHint    (1L << 5)
#define WindowGroupHint (1L << 6)
#define AllHints (InputHint|StateHint|IconPixmapHint|IconWindowHint|IconPositionHint|IconMaskHint|WindowGroupHint)
#define XStringStyle    (1L << 0)
#define XTextStyle      (1L << 1)
#define XStdICCTextStyle (1L << 2)
#define XCompoundTextStyle (1L << 3)
#define XUTF8StringStyle (1L << 4)

typedef struct {
    long flags;
    int x, y;
    int width, height;
    int min_width, min_height;
    int max_width, max_height;
    int width_inc, height_inc;
    struct { int x; int y; } min_aspect, max_aspect;
    int base_width, base_height;
    int win_gravity;
} XSizeHints;

typedef struct {
    long flags;
    Bool input;
    int initial_state;
    Pixmap icon_pixmap;
    Window icon_window;
    int icon_x, icon_y;
    Pixmap icon_mask;
    XID window_group;
} XWMHints;

typedef struct {
    char *res_name;
    char *res_class;
} XClassHint;

typedef struct {
    unsigned char *value;
    Atom encoding;
    int format;
    unsigned long nitems;
} XTextProperty;

typedef struct {
    int size;
    Time time;
    int state;
} XComposeStatus;

/* XVisualInfo 属于 Xutil.h（glx.h 从 <X11/Xutil.h> 里取它）。 */
typedef struct {
    Visual *visual;
    VisualID visualid;
    int screen;
    int depth;
#if defined(__cplusplus) || defined(c_plusplus)
    int c_class;
#else
    int class;
#endif
    unsigned long red_mask;
    unsigned long green_mask;
    unsigned long blue_mask;
    int colormap_size;
    int bits_per_rgb;
} XVisualInfo;

/* Xlib/Xutil 里几个 JDK 的头会用到的类型（libawt 的 `!HEADLESS` 分支只有
 * 结构体定义，不调用 X 函数，所以只要类型齐全就能过编译）。
 * XPixmapFormatValues / XChar2b / XCharStruct 定义在 Xlib.h。 */
typedef struct _XRegion *Region;

typedef struct {
    char *chars;
    int nchars;
    int delta;
    Font font;
} XTextItem;

typedef struct {
    XChar2b *chars;
    int nchars;
    int delta;
    Font font;
} XTextItem16;

extern Region  XCreateRegion(void);
extern int     XDestroyRegion(Region r);
extern int     XSetRegion(Display *display, GC gc, Region r);
extern int     XUnionRectWithRegion(XRectangle *rectangle, Region src, Region dest);
extern int     XIntersectRegion(Region a, Region b, Region r);
extern int     XSubtractRegion(Region a, Region b, Region r);
extern int     XUnionRegion(Region a, Region b, Region r);
extern int     XXorRegion(Region a, Region b, Region r);
extern int     XRectInRegion(Region r, int x, int y, unsigned int width, unsigned int height);
extern int     XEmptyRegion(Region r);
extern int     XOffsetRegion(Region r, int dx, int dy);
extern Bool    XPointInRegion(Region r, int x, int y);
extern Region  XPolygonRegion(XPoint *points, int n, int fill_rule);

extern int        XGetWMNormalHints(Display *display, Window w, XSizeHints *hints_return, long *supplied_return);
extern XClassHint *XAllocClassHint(void);
extern XSizeHints *XAllocSizeHints(void);
extern XWMHints  *XAllocWMHints(void);
extern Status     XGetWindowProperty(Display *display, Window w, Atom property,
                                     long offset, long length, Bool delete_prop, Atom req_type,
                                     Atom *actual_type_return, int *actual_format_return,
                                     unsigned long *nitems_return,
                                     unsigned long *bytes_after_return,
                                     unsigned char **prop_return);
extern Status     XGetTextProperty(Display *display, Window window, XTextProperty *tp, Atom property);

#endif /* BSH_STUB_X11_XUTIL_H */
