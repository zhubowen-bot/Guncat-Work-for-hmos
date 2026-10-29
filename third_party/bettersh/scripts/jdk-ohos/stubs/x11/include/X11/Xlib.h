/*
 * X11/Xlib.h — 给 OHOS 上的 JDK 用的 X11 桩头
 *
 * 为什么需要：make/autoconf/lib-x11.m4 对非 windows/macosx 的 target 一律
 * NEEDS_LIB_X11=true，并用 AC_CHECK_HEADERS 验
 *   X11/extensions/{shape,Xrender,XTest,Xrandr}.h + X11/Intrinsic.h
 * （编译探针里先 include <X11/Xlib.h> 和 <X11/Xutil.h>）。
 * 少了任何一个 configure 直接 AC_MSG_ERROR。
 *
 * 而 `--enable-headless-only` 下真正链接 X11 的 libawt_xawt / libsplashscreen
 * 都不构建，所以这些头只在**编译期**存在即可，没有任何实现需求。
 * 注意 libawt 的 CFLAGS 里有 `$(X_CFLAGS)`，也就是说这个目录会被加到
 * libawt 的包含路径上——所以内容要能真的过编译，不能只是一句空话。
 *
 * 覆盖范围按 src/java.desktop 在 headless 配置下实际碰到的标识符裁剪，
 * 不是照抄上游 Xlib.h。
 */
#ifndef BSH_STUB_X11_XLIB_H
#define BSH_STUB_X11_XLIB_H

#include <X11/X.h>
#include <X11/Xfuncproto.h>
#include <X11/Xmd.h>

#define X_PROTOCOL 11
#define X_PROTOCOL_REVISION 0

typedef struct _XDisplay Display;
typedef struct _XScreen  Screen;
typedef struct _XVisual  Visual;
typedef struct _XExtData XExtData;
typedef struct _XGC      *GC;
typedef char *XPointer;

typedef struct {
    short x, y;
} XPoint;

typedef struct {
    short x, y;
    unsigned short width, height;
} XRectangle;

typedef struct {
    short x1, y1, x2, y2;
} XSegment;

typedef struct {
    unsigned long pixel;
    unsigned short red, green, blue;
    char flags;
    char pad;
} XColor;

typedef struct {
    int x, y;
    int width, height;
    int border_width;
    int depth;
    Visual *visual;
    Window root;
#if defined(__cplusplus) || defined(c_plusplus)
    int c_class;
#else
    int class;
#endif
    int bit_gravity;
    int win_gravity;
    int backing_store;
    unsigned long backing_planes;
    unsigned long backing_pixel;
    Bool save_under;
    Colormap colormap;
    Bool map_installed;
    int map_state;
    long all_event_masks;
    long your_event_mask;
    long do_not_propagate_mask;
    Bool override_redirect;
    Screen *screen;
} XWindowAttributes;

typedef struct {
    int x, y;
    int width, height;
    int border_width;
    int depth;
    int visual;
    Visual *visual_ptr;
    Colormap colormap;
    unsigned long valuemask;
} XSetWindowAttributes;

typedef struct {
    int function;
    unsigned long plane_mask;
    unsigned long foreground;
    unsigned long background;
    int line_width;
    int line_style;
    int cap_style;
    int join_style;
    int fill_style;
    int fill_rule;
    int arc_mode;
    Pixmap tile;
    Pixmap stipple;
    int ts_x_origin;
    int ts_y_origin;
    Font font;
    int subwindow_mode;
    Bool graphics_exposures;
    int clip_x_origin;
    int clip_y_origin;
    Pixmap clip_mask;
    int dash_offset;
    char dashes;
} XGCValues;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Window root;
    Window subwindow;
    Time time;
    int x, y, x_root, y_root;
    unsigned int state;
    unsigned int keycode;
    Bool same_screen;
} XKeyEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Window root;
    Window subwindow;
    Time time;
    int x, y, x_root, y_root;
    unsigned int state;
    unsigned int button;
    Bool same_screen;
} XButtonEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Window root;
    Window subwindow;
    Time time;
    int x, y, x_root, y_root;
    unsigned int state;
    char is_hint;
    Bool same_screen;
} XMotionEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window event;
    Window window;
    int x, y;
    int width, height;
    int border_width;
    Window above;
    Bool override_redirect;
} XConfigureEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    int x, y;
    int width, height;
    int count;
} XExposeEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Atom message_type;
    int format;
    union {
        char b[20];
        short s[10];
        long l[5];
    } data;
} XClientMessageEvent;

typedef union _XEvent {
    int type;
    XKeyEvent xkey;
    XButtonEvent xbutton;
    XMotionEvent xmotion;
    XConfigureEvent xconfigure;
    XExposeEvent xexpose;
    XClientMessageEvent xclient;
    long pad[24];
} XEvent;

typedef struct {
    unsigned char *data;
    int width, height;
    int xoffset;
    int format;
    char *f;
    int byte_order;
    int bitmap_unit;
    int bitmap_bit_order;
    int bitmap_pad;
    int depth;
    int bytes_per_line;
    int bits_per_pixel;
    unsigned long red_mask, green_mask, blue_mask;
} XImage;

typedef struct {
    unsigned char byte1;
    unsigned char byte2;
} XChar2b;

typedef struct {
    int depth;
    int bits_per_pixel;
    int scanline_pad;
} XPixmapFormatValues;

typedef struct {
    short lbearing, rbearing, width, ascent, descent;
    unsigned short attributes;
} XCharStruct;

typedef struct {
    XExtData *ext_data;
    Font fid;
    unsigned int direction, min_char_or_byte2, max_char_or_byte2;
    unsigned int min_byte1, max_byte1;
    Bool all_chars_exist;
    unsigned int default_char;
    int n_properties;
    XCharStruct *per_char;
    XCharStruct max_bounds;
    unsigned int ascent, descent;
} XFontStruct;

/* ── 常量 ────────────────────────────────────────────────── */
#define XA_PRIMARY   1L
#define XA_SECONDARY 2L
#define XA_ARC       3L
#define XA_ATOM      4L
#define XA_BITMAP    5L
#define XA_CARDINAL  6L
#define XA_COLORMAP  7L
#define XA_CURSOR    8L
#define XA_CUT_BUFFER0 9L
#define XA_DRAWABLE  17L
#define XA_FONT      18L
#define XA_INTEGER   19L
#define XA_PIXMAP    20L
#define XA_POINT     21L
#define XA_RECTANGLE 22L
#define XA_RESOURCE_MANAGER 23L
#define XA_RGB_COLOR_MAP 24L
#define XA_RGB_BEST_MAP 25L
#define XA_RGB_BLUE_MAP 26L
#define XA_RGB_DEFAULT_MAP 27L
#define XA_RGB_GRAY_MAP 28L
#define XA_RGB_GREEN_MAP 29L
#define XA_RGB_RED_MAP 30L
#define XA_STRING    31L
#define XA_VISUALID  32L
#define XA_WINDOW    33L
#define XA_WM_COMMAND 34L
#define XA_WM_CLASS  67L
#define XA_WM_NAME   39L
#define XA_WM_NORMAL_HINTS 40L
#define XA_WM_HINTS  35L
#define XA_WM_ICON_NAME 37L
#define XA_WM_TRANSIENT_FOR 68L

#define XlibSpecificationRelease 6
#define AllPlanes ((unsigned long)~0L)
#define BlackPixel(d, s) 0
#define WhitePixel(d, s) 1
#define DefaultScreen(dpy) 0
#define DefaultRootWindow(dpy) 0L
#define DefaultVisual(dpy, scr) ((Visual *)0)
#define DefaultDepth(dpy, scr) 24
#define DefaultColormap(dpy, scr) 0L
#define RootWindow(dpy, scr) DefaultRootWindow(dpy)
#define DisplayString(dpy) ((char *)0)
#define DisplayWidth(dpy, scr) 0
#define DisplayHeight(dpy, scr) 0
#define DisplayWidthMM(dpy, scr) 0
#define DisplayHeightMM(dpy, scr) 0
#define DisplayPlanes(dpy, scr) 24
#define ScreenCount(dpy) 1

#define NoEventMask           0L
#define KeyPressMask          (1L<<0)
#define KeyReleaseMask        (1L<<1)
#define ButtonPressMask       (1L<<2)
#define ButtonReleaseMask     (1L<<3)
#define EnterWindowMask       (1L<<4)
#define LeaveWindowMask       (1L<<5)
#define PointerMotionMask     (1L<<6)
#define ExposureMask          (1L<<15)
#define StructureNotifyMask   (1L<<17)
#define SubstructureNotifyMask (1L<<19)
#define PropertyChangeMask    (1L<<22)
#define FocusChangeMask       (1L<<21)
#define VisibilityChangeMask  (1L<<16)
#define ColormapChangeMask    (1L<<23)
#define OwnerGrabButtonMask   (1L<<24)

#define CWBackPixmap   (1L<<0)
#define CWBackPixel    (1L<<1)
#define CWBorderPixmap (1L<<2)
#define CWBorderPixel  (1L<<3)
#define CWBitGravity   (1L<<4)
#define CWWinGravity   (1L<<5)
#define CWBackingStore (1L<<6)
#define CWBackingPlanes (1L<<7)
#define CWBackingPixel (1L<<8)
#define CWOverrideRedirect (1L<<9)
#define CWSaveUnder    (1L<<10)
#define CWEventMask    (1L<<11)
#define CWDontPropagate (1L<<12)
#define CWColormap     (1L<<13)
#define CWCursor       (1L<<14)

#define GCFunction     (1L<<0)
#define GCPlaneMask    (1L<<1)
#define GCForeground   (1L<<2)
#define GCBackground   (1L<<3)
#define GCLineWidth    (1L<<4)
#define GCLineStyle    (1L<<5)
#define GCCapStyle     (1L<<6)
#define GCJoinStyle    (1L<<7)
#define GCFillStyle    (1L<<8)
#define GCFillRule     (1L<<9)
#define GCTile         (1L<<10)
#define GCClipMask     (1L<<19)
#define GCSubwindowMode (1L<<15)

#define GXcopy   3
#define GXxor    6
#define GXor     7
#define LineSolid 0
#define CapButt  1
#define JoinMiter 0
#define FillSolid 0
#define FillStippled 2
#define EvenOddRule 0
#define ArcPieSlice 0
#define ClipByChildren 0
#define IncludeInferiors 1
#define CoordModeOrigin 0
#define XYBitmap 0
#define XYPixmap 1
#define ZPixmap  2
#define LSBFirst 0
#define MSBFirst 1
#define Complex  0
#define Nonconvex 1
#define Convex 2
#define Unsorted 0
#define IsUnmapped 0
#define IsUnviewable 1
#define IsViewable 2
#define StaticGray 0
#define GrayScale 1
#define StaticColor 2
#define PseudoColor 3
#define TrueColor 4
#define DirectColor 5
#define InputOutput 1
#define InputOnly 2

#define XK_MISCELLANY
#define XK_LATIN1
#define XK_XKB_KEYS

#include <X11/keysym.h>

/* ── 函数原型（headless 构建不链接 X11，仅为可读性保留）────── */
extern Display *XOpenDisplay(_Xconst char *display_name);
extern int      XCloseDisplay(Display *display);
extern int      XFree(void *data);
extern Screen  *XDefaultScreenOfDisplay(Display *display);
extern int      XDefaultScreen(Display *display);
extern int      XDefaultDepth(Display *display, int screen_number);
extern Visual  *XDefaultVisual(Display *display, int screen_number);
extern Colormap XDefaultColormap(Display *display, int screen_number);
extern Window   XDefaultRootWindow(Display *display);
extern int      XScreenCount(Display *display);
extern char    *XDisplayString(Display *display);
extern int      XDisplayWidth(Display *display, int screen_number);
extern int      XDisplayHeight(Display *display, int screen_number);
extern int      XDisplayWidthMM(Display *display, int screen_number);
extern int      XDisplayHeightMM(Display *display, int screen_number);
extern int      XDisplayPlanes(Display *display, int screen_number);
extern int      XConnectionNumber(Display *display);
extern Atom     XInternAtom(Display *display, _Xconst char *atom_name, Bool only_if_exists);
extern char    *XGetAtomName(Display *display, Atom atom);
extern int      XCreateWindow(Display *display, Window parent, int x, int y,
                              unsigned int width, unsigned int height,
                              unsigned int border_width, int depth,
                              unsigned int clazz, Visual *visual,
                              unsigned long valuemask, XSetWindowAttributes *attributes);
extern int      XDestroyWindow(Display *display, Window w);
extern int      XMapWindow(Display *display, Window w);
extern int      XUnmapWindow(Display *display, Window w);
extern int      XNextEvent(Display *display, XEvent *event_return);
extern int      XPending(Display *display);
extern int      XFlush(Display *display);
extern int      XSync(Display *display, Bool discard);
extern GC       XCreateGC(Display *display, Drawable d, unsigned long valuemask, XGCValues *values);
extern int      XFreeGC(Display *display, GC gc);
extern int      XSetForeground(Display *display, GC gc, unsigned long foreground);
extern int      XSetBackground(Display *display, GC gc, unsigned long background);
extern int      XFillRectangle(Display *display, Drawable d, GC gc,
                               int x, int y, unsigned int width, unsigned int height);
extern int      XDrawString(Display *display, Drawable d, GC gc, int x, int y,
                            _Xconst char *string, int length);
extern int      XGetWindowAttributes(Display *display, Window w, XWindowAttributes *attributes);
extern int      XGetGeometry(Display *display, Drawable d, Window *root_return,
                             int *x_return, int *y_return,
                             unsigned int *width_return, unsigned int *height_return,
                             unsigned int *border_width_return, unsigned int *depth_return);
extern char    *XGetFontPath(Display *display, int *npaths_return);
extern int      XFreeFontPath(char **list);
extern int      XSetLocaleModifiers(_Xconst char *modifier_list);

/* libawt 在 headless 下只用到类型，不上这些函数；声明纯属为了换配置时
 * （比如加回 xawt）头文件不至于缺标识符。 */
typedef struct {
    int type;
    Display *display;
    Window resourceid;
    unsigned long serial;
    unsigned char error_code;
    unsigned char request_code;
    unsigned char minor_code;
} XErrorEvent;

typedef int (*XErrorHandler)(Display *display, XErrorEvent *event);

extern XErrorHandler XSetErrorHandler(XErrorHandler handler);
extern int      XGetErrorText(Display *display, int code, char *buffer_return, int length);
extern XImage  *XCreateImage(Display *display, Visual *visual, unsigned int depth,
                             int format, int offset, char *data, unsigned int width,
                             unsigned int height, int bitmap_pad, int bytes_per_line);
extern int      XDestroyImage(XImage *ximage);
extern XImage  *XGetImage(Display *display, Drawable d, int x, int y,
                          unsigned int width, unsigned int height,
                          unsigned long plane_mask, int format);
extern int      XPutImage(Display *display, Drawable d, GC gc, XImage *image,
                          int src_x, int src_y, int dest_x, int dest_y,
                          unsigned int width, unsigned int height);
extern Pixmap   XCreatePixmap(Display *display, Drawable d, unsigned int width,
                              unsigned int height, unsigned int depth);
extern int      XFreePixmap(Display *display, Pixmap pixmap);
extern Colormap XCreateColormap(Display *display, Window w, Visual *visual, int alloc);
extern int      XFreeColormap(Display *display, Colormap colormap);
extern Status   XAllocColor(Display *display, Colormap colormap, XColor *screen_in_out);
extern Status   XAllocColorCells(Display *display, Colormap colormap, Bool contig,
                                 unsigned long *plane_masks_return, unsigned int nplanes,
                                 unsigned long *pixels_return, unsigned int npixels);
extern int      XFreeColors(Display *display, Colormap colormap,
                            unsigned long *pixels, int npixels, unsigned long planes);
extern int      XQueryColors(Display *display, Colormap colormap, XColor *defs_in_out, int ncolors);
extern int      XChangeGC(Display *display, GC gc, unsigned long valuemask, XGCValues *values);
extern XPixmapFormatValues *XListPixmapFormats(Display *display, int *count_return);
extern char   **XListFonts(Display *display, _Xconst char *pattern, int maxnames, int *count_return);
extern int      XFreeFontNames(char **list);
extern XFontStruct *XLoadQueryFont(Display *display, _Xconst char *name);
extern int      XFreeFont(Display *display, XFontStruct *font_struct);
extern int      XGrabServer(Display *display);
extern int      XUngrabServer(Display *display);
extern int      XCopyArea(Display *display, Drawable src, Drawable dest, GC gc,
                          int src_x, int src_y, unsigned int width, unsigned int height,
                          int dest_x, int dest_y);
extern int      XFillPolygon(Display *display, Drawable d, GC gc, XPoint *points,
                             int npoints, int shape, int mode);
extern int      XDrawLines(Display *display, Drawable d, GC gc, XPoint *points,
                           int npoints, int mode);
extern int      XDrawArc(Display *display, Drawable d, GC gc, int x, int y,
                         unsigned int width, unsigned int height, int angle1, int angle2);
extern int      XDrawRectangle(Display *display, Drawable d, GC gc, int x, int y,
                               unsigned int width, unsigned int height);
extern int      XFillArc(Display *display, Drawable d, GC gc, int x, int y,
                         unsigned int width, unsigned int height, int angle1, int angle2);
extern int      XFillSpans(Display *display, Drawable d, GC gc, XPoint *points,
                           int *widths, int nspans, int sorted);
extern int      XQueryTextExtents16(Display *display, XID font_ID, XChar2b *string,
                                    int nchars, int *direction_return,
                                    int *font_ascent_return, int *font_descent_return,
                                    XCharStruct *overall_return);
extern int      XDrawString16(Display *display, Drawable d, GC gc, int x, int y,
                              XChar2b *string, int length);

#endif /* BSH_STUB_X11_XLIB_H */
