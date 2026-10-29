/*
 * X11/Xatom.h — X11 桩头的一部分（见 X11/Xlib.h 顶部说明）
 *
 * 上游这里是一堆 "XA_*" 的 extern char* 声明；headless 构建不链接 X11，
 * 所以只需要让标识符可见，值不重要。
 */
#ifndef BSH_STUB_X11_XATOM_H
#define BSH_STUB_X11_XATOM_H

#include <X11/X.h>
#include <X11/Xlib.h>

#define XA_LAST_PREDEFINED 68

extern char *Xatom_XA_PRIMARY;
extern char *Xatom_XA_STRING;
extern char *Xatom_XA_ATOM;
extern char *Xatom_XA_CARDINAL;
extern char *Xatom_XA_WINDOW;
extern char *Xatom_XA_WM_NAME;
extern char *Xatom_XA_WM_CLASS;
extern char *Xatom_XA_WM_PROTOCOLS;
extern char *Xatom_XA_WM_DELETE_WINDOW;

#define XA_WM_PROTOCOLS 61L
#define XA_WM_DELETE_WINDOW 62L

#endif /* BSH_STUB_X11_XATOM_H */
