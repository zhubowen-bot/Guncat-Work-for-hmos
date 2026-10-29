/*
 * X11/keysym.h — X11 桩头的一部分（见 X11/Xlib.h 顶部说明）
 *
 * 只给 headless 编译兜底：真正的 keysym 表在 libawt_xawt 里用，
 * 而 libawt_xawt 在 --enable-headless-only 下不构建。
 */
#ifndef BSH_STUB_X11_KEYSYM_H
#define BSH_STUB_X11_KEYSYM_H

#define XK_VoidSymbol       0xffffff
#define XK_BackSpace        0xff08
#define XK_Tab              0xff09
#define XK_Linefeed         0xff0a
#define XK_Clear            0xff0b
#define XK_Return           0xff0d
#define XK_Pause            0xff13
#define XK_Scroll_Lock      0xff14
#define XK_Sys_Req          0xff15
#define XK_Escape           0xff1b
#define XK_Delete           0xffff
#define XK_Home             0xff50
#define XK_Left             0xff51
#define XK_Up               0xff52
#define XK_Right            0xff53
#define XK_Down             0xff54
#define XK_Page_Up          0xff55
#define XK_Page_Down        0xff56
#define XK_End              0xff57
#define XK_Begin            0xff58
#define XK_Select           0xff60
#define XK_Print            0xff61
#define XK_Execute          0xff62
#define XK_Insert           0xff63
#define XK_Undo             0xff65
#define XK_Redo             0xff66
#define XK_Menu             0xff67
#define XK_Find             0xff68
#define XK_Cancel           0xff69
#define XK_Help             0xff6a
#define XK_Break            0xff6b
#define XK_Mode_switch      0xff7e
#define XK_Num_Lock         0xff7f

#define XK_Shift_L          0xffe1
#define XK_Shift_R          0xffe2
#define XK_Control_L        0xffe3
#define XK_Control_R        0xffe4
#define XK_Caps_Lock        0xffe5
#define XK_Shift_Lock       0xffe6
#define XK_Meta_L           0xffe7
#define XK_Meta_R           0xffe8
#define XK_Alt_L            0xffe9
#define XK_Alt_R            0xffea
#define XK_Super_L          0xffeb
#define XK_Super_R          0xffec
#define XK_Hyper_L          0xffed
#define XK_Hyper_R          0xffee

#define XK_space            0x0020
#define XK_exclam           0x0021
#define XK_quotedbl         0x0022
#define XK_numbersign       0x0023
#define XK_dollar           0x0024
#define XK_percent          0x0025
#define XK_ampersand        0x0026
#define XK_apostrophe       0x0027
#define XK_parenleft        0x0028
#define XK_parenright       0x0029
#define XK_asterisk         0x002a
#define XK_plus             0x002b
#define XK_comma            0x002c
#define XK_minus            0x002d
#define XK_period           0x002e
#define XK_slash            0x002f
#define XK_0                0x0030
#define XK_1                0x0031
#define XK_2                0x0032
#define XK_3                0x0033
#define XK_4                0x0034
#define XK_5                0x0035
#define XK_6                0x0036
#define XK_7                0x0037
#define XK_8                0x0038
#define XK_9                0x0039
#define XK_A                0x0041
#define XK_Z                0x005a
#define XK_a                0x0061
#define XK_z                0x007a

#define XK_F1               0xffbe
#define XK_F12              0xffc9

#endif /* BSH_STUB_X11_KEYSYM_H */
