/*
 * cups/cups.h — 给 OHOS 上的 JDK 用的 CUPS 桩头
 *
 * JDK 的 java.desktop 在非 windows 平台强制 NEEDS_LIB_CUPS=true（见
 * make/autoconf/libraries.m4），configure 会用 `--with-cups-include` 指到的目录里
 * 找 `cups/cups.h`（lib-cups.m4 只做 `-s` 存在性检查）。
 *
 * 运行时 CUPS 是 dlopen 的（src/java.desktop/unix/native/common/awt/CUPSfuncs.c
 * 全程 dlsym），所以这里只需要把**编译期用到的类型**铺对，不需要任何实现。
 *
 * 本文件声明的是 CUPSfuncs.c 实际触碰到的部分：
 *   cups_dest_t（读 .name，作为数组元素）、cupsGetDest/cupsGetDests/cupsFreeDests 的签名。
 */
#ifndef BSH_STUB_CUPS_CUPS_H
#define BSH_STUB_CUPS_CUPS_H

#ifdef __cplusplus
extern "C" {
#endif

/* 选项是 "名字=值" 的字符串数组；JDK 只是把它透传给 cupsGetDest。 */
typedef struct cups_option_s {
    char* name;
    char* value;
} cups_option_t;

/* CUPSfuncs.c 用 http_t 只是做 httpConnect/httpClose 的指针中转，
 * 结构体内容 JDK 从不读，保持不透明即可。 */
typedef struct _http_s http_t;

/*
 * 字段顺序必须和真 CUPS 一致：JDK 直接读 dests[i].name / dest->name，
 * 而结构体是 CUPS 库自己分配的，我们只负责让偏移量对得上。
 */
typedef struct cups_dest_s {
    char* name;
    char* instance;
    int   is_default;
    int   num_options;
    cups_option_t* options;
} cups_dest_t;

int           cupsGetDests(cups_dest_t** dests);
void          cupsFreeDests(int num_dests, cups_dest_t* dests);
cups_dest_t*  cupsGetDest(const char* name, const char* instance,
                          int num_dests, cups_dest_t* dests);

/* CUPSfuncs.c 里还引用了这个（走 dlsym，声明只为过编译）。 */
const char*   cupsGetPPD(const char* printer);

#ifdef __cplusplus
}
#endif

#endif /* BSH_STUB_CUPS_CUPS_H */
