/*
 * fontconfig/fontconfig.h — 给 OHOS 上的 JDK 用的 fontconfig 桩头
 *
 * 为什么需要：make/autoconf/libraries.m4 对所有非 windows/macosx 的 target 无条件
 * 设 NEEDS_LIB_FONTCONFIG=true（"even if building headless only, libawt still needs
 * fontconfig headers"），lib-fontconfig.m4 会拿 `--with-fontconfig-include` 指到的
 * 目录里找 `fontconfig/fontconfig.h`，找不到直接 AC_MSG_ERROR。
 *
 * 运行时 fontconfig 是 dlopen 的（src/java.desktop/unix/native/common/awt/fontpath.c
 * 全程 dlsym + 自己 typedef 函数指针），所以这里只需要**类型和常量**，
 * 一个函数实现都不需要。JDK 自己 typedef 了所有函数指针类型，
 * 所以这里连函数原型都可以不写——但写上便于人读。
 *
 * 覆盖范围 = fontpath.c 实际引用到的标识符（用 grep 出来的，不是照抄上游头文件）。
 */
#ifndef BSH_STUB_FONTCONFIG_FONTCONFIG_H
#define BSH_STUB_FONTCONFIG_FONTCONFIG_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned char  FcChar8;
typedef unsigned int   FcChar32;
typedef int            FcBool;

#define FcFalse 0
#define FcTrue  1

/* ── 不透明句柄 ──────────────────────────────────────────── */
typedef struct _FcConfig    FcConfig;
typedef struct _FcPattern   FcPattern;
typedef struct _FcCharSet   FcCharSet;
typedef struct _FcObjectSet FcObjectSet;
typedef struct _FcStrList   FcStrList;

/* FcFontSet 必须把布局铺出来：fontpath.c 直接读 nfont / fonts[]。 */
typedef struct _FcFontSet {
    int         nfont;
    int         sfont;
    FcPattern** fonts;
} FcFontSet;

/* ── 枚举 ────────────────────────────────────────────────── */
typedef enum _FcResult {
    FcResultMatch = 0,
    FcResultNoMatch,
    FcResultTypeMismatch,
    FcResultNoId,
    FcResultOutOfMemory
} FcResult;

typedef enum _FcMatchKind {
    FcMatchPattern = 0,
    FcMatchFont,
    FcMatchScan
} FcMatchKind;

typedef enum _FcType {
    FcTypeUnknown = -1,
    FcTypeVoid,
    FcTypeInteger,
    FcTypeDouble,
    FcTypeString,
    FcTypeBool,
    FcTypeMatrix,
    FcTypeCharSet,
    FcTypeFTFace,
    FcTypeLangSet,
    FcTypeRange
} FcType;

/* subpixel 渲染方式；JDK 按"UNKNOWN 最小、NONE 最大"的区间做判断。 */
#define FC_RGBA_UNKNOWN 0
#define FC_RGBA_RGB     1
#define FC_RGBA_BGR     2
#define FC_RGBA_VRGB    3
#define FC_RGBA_VBGR    4
#define FC_RGBA_NONE    5

/* ── 属性名字符串 ────────────────────────────────────────── */
#define FC_FAMILY       "family"
#define FC_STYLE        "style"
#define FC_FULLNAME     "fullname"
#define FC_FILE         "file"
#define FC_LANG         "lang"
#define FC_FONTFORMAT   "fontformat"
#define FC_CHARSET      "charset"
#define FC_OUTLINE      "outline"
#define FC_ANTIALIAS    "antialias"
#define FC_RGBA         "rgba"

/* ── 函数原型（仅供阅读；调用点都是 dlsym 出来的）────────────
 * 注意：JDK 不直接调用任何 Fc* 函数，这里的原型不进任何链接。 */
FcConfig*   FcInitLoadConfig(void);
void        FcFini(void);
int         FcGetVersion(void);
FcPattern*  FcPatternBuild(FcPattern* pattern, ...);
FcObjectSet* FcObjectSetBuild(const char* first, ...);
FcFontSet*  FcFontList(FcConfig* config, FcPattern* p, FcObjectSet* os);
FcStrList*  FcConfigGetCacheDirs(FcConfig* config);
FcChar8*    FcStrListNext(FcStrList* list);
FcChar8*    FcStrListDone(FcStrList* list);
FcPattern*  FcNameParse(const FcChar8* name);
FcBool      FcPatternAddString(FcPattern* p, const char* object, const FcChar8* s);
void        FcPatternDestroy(FcPattern* p);
void        FcObjectSetDestroy(FcObjectSet* os);
void        FcFontSetDestroy(FcFontSet* s);
FcBool      FcConfigSubstitute(FcConfig* config, FcPattern* p, FcMatchKind kind);
void        FcDefaultSubstitute(FcPattern* p);
FcPattern*  FcFontMatch(FcConfig* config, FcPattern* p, FcResult* result);
FcResult    FcPatternGetString(const FcPattern* p, const char* object, int id, FcChar8** s);
FcResult    FcPatternGetBool(const FcPattern* p, const char* object, int id, FcBool* b);
FcResult    FcPatternGetInteger(const FcPattern* p, const char* object, int id, int* i);
FcResult    FcPatternGetCharSet(FcPattern* p, const char* object, int id, FcCharSet** c);
FcFontSet*  FcFontSort(FcConfig* config, FcPattern* p, FcBool trim, FcCharSet** csp, FcResult* result);
FcFontSet*  FcFontRenderPrepare(FcConfig* config, FcPattern* pat, FcPattern* font);
FcCharSet*  FcCharSetUnion(const FcCharSet* a, const FcCharSet* b);
FcCharSet*  FcCharSetDestroy(FcCharSet* fcs);
FcChar32    FcCharSetSubtractCount(const FcCharSet* a, const FcCharSet* b);
FcChar8*    FcStrDirname(const FcChar8* file);

#ifdef __cplusplus
}
#endif

#endif /* BSH_STUB_FONTCONFIG_FONTCONFIG_H */
