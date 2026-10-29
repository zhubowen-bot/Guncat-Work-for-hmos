/*
 * X11/X.h — X11 桩头的一部分（见 X11/Xlib.h 顶部说明）
 */
#ifndef BSH_STUB_X11_X_H
#define BSH_STUB_X11_X_H

#include <X11/Xmd.h>

#define Bool   int
#define True   1
#define False  0

#define None   0L
#define ParentRelative 1L

typedef unsigned long  Atom;
typedef unsigned long  VisualID;
typedef unsigned long  XID;
typedef int            Status;
typedef XID            Window;
typedef XID            Drawable;
typedef XID            Pixmap;
typedef XID            Colormap;
typedef XID            Cursor;
typedef XID            KeySym;
typedef XID            Font;
typedef CARD32         Time;
typedef CARD32         KeyCode;

#define CopyFromParent 0L
#define PointerWindow  0L
#define InputFocus     1L
#define PointerRoot    1L
#define AnyPropertyType 0L
#define AnyKey         0L
#define AnyButton      0L
#define AllTemporary   0L
#define CurrentTime    0L
#define RevertToNone   0
#define RevertToParent 1
#define RevertToPointerRoot 2

#define KeyPress           2
#define KeyRelease         3
#define ButtonPress        4
#define ButtonRelease      5
#define MotionNotify       6
#define EnterNotify        7
#define LeaveNotify        8
#define FocusIn            9
#define FocusOut          10
#define KeymapNotify      11
#define Expose            12
#define GraphicsExpose    13
#define NoExpose          14
#define VisibilityNotify  15
#define CreateNotify      16
#define DestroyNotify     17
#define UnmapNotify       18
#define MapNotify         19
#define MapRequest        20
#define ReparentNotify    21
#define ConfigureNotify   22
#define ConfigureRequest  23
#define GravityNotify     24
#define ResizeRequest     25
#define CirculateNotify   26
#define CirculateRequest  27
#define PropertyNotify    28
#define SelectionClear    29
#define SelectionRequest  30
#define SelectionNotify   31
#define ColormapNotify    32
#define ClientMessage     33
#define MappingNotify     34
#define GenericEvent      35

#define ShiftMask   (1<<0)
#define LockMask    (1<<1)
#define ControlMask (1<<2)
#define Mod1Mask    (1<<3)
#define Mod2Mask    (1<<4)
#define Mod3Mask    (1<<5)
#define Mod4Mask    (1<<6)
#define Mod5Mask    (1<<7)
#define Button1Mask (1<<8)
#define Button2Mask (1<<9)
#define Button3Mask (1<<10)
#define Button4Mask (1<<11)
#define Button5Mask (1<<12)
#define AnyModifier (1<<15)

#endif /* BSH_STUB_X11_X_H */
