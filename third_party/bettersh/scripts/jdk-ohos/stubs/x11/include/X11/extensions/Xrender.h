/*
 * X11/extensions/Xrender.h — X11 桩头（见 X11/Xlib.h 顶部说明）
 *
 * lib-x11.m4 的 AC_CHECK_HEADERS 探针之一。
 */
#ifndef BSH_STUB_X11_EXT_XRENDER_H
#define BSH_STUB_X11_EXT_XRENDER_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define RENDER_NAME "RENDER"
#define RENDER_MAJOR 0
#define RENDER_MINOR 11

#define PictTypeIndexed 0
#define PictTypeDirect  1

#define PolyEdgeSharp   0
#define PolyEdgeSmooth  1

#define PolyModePrecise 0
#define PolyModeImprecise 1

#define PictOpClear      0
#define PictOpSrc        1
#define PictOpDst        2
#define PictOpOver       3
#define PictOpIn         4
#define PictOpOut        5
#define PictOpAtop       6
#define PictOpXor        7
#define PictOpAdd        8

#define PictStandardARGB32 0
#define PictStandardRGB24  1
#define PictStandardA8     2
#define PictStandardA4     3
#define PictStandardA1     4

#define XRenderFindVisualFormat 0
#define XRenderFindStandardFormat 0
#define XRenderFindFormat 0
#define XRenderCreatePicture 0
#define XRenderFreePicture 0
#define XRenderComposite 0
#define XRenderCreatePixmap 0
#define XRenderCreateSolidFill 0
#define XRenderSetPictureTransform 0

typedef unsigned long  Glyph;
typedef unsigned long  GlyphSet;
typedef unsigned long  Picture;
typedef unsigned long  PictFormat;
typedef XID            XRenderPictFormat;

typedef struct {
    short red, green, blue, alpha;
} XRenderColor;

typedef struct {
    int x, y;
    unsigned int width, height;
    int xOff, yOff;
} XGlyphInfo;

#endif /* BSH_STUB_X11_EXT_XRENDER_H */
