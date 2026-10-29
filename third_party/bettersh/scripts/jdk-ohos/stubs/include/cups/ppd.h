/*
 * cups/ppd.h — 给 OHOS 上的 JDK 用的 PPD 桩头
 *
 * 只覆盖 CUPSfuncs.c 的 Java_sun_print_CUPSPrinter_getMedia 用到的字段：
 *   ppd_option_t { num_choices, choices } / ppd_choice_t { choice, text }
 *   ppd_size_t   { width, length, left, right, top, bottom }
 * 其余字段（以及 ppd_file_t 的内容）JDK 从不读，保持不透明即可。
 */
#ifndef BSH_STUB_CUPS_PPD_H
#define BSH_STUB_CUPS_PPD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ppd_choice_s {
    char* choice;   /* 机器可读的选项名 */
    char* text;     /* 人类可读的描述 */
    char* marked;   /* 是否被标记 */
} ppd_choice_t;

typedef struct ppd_option_s {
    char*         defchoice;
    char*         text;
    char*         keyword;
    char*         section;
    int           order;
    int           num_choices;
    ppd_choice_t* choices;
} ppd_option_t;

typedef struct ppd_size_s {
    char*  name;
    float  width;
    float  length;
    float  left;
    float  bottom;
    float  right;
    float  top;
    int    order;
} ppd_size_t;

typedef struct ppd_group_s ppd_group_t;

typedef struct ppd_file_s ppd_file_t;

ppd_file_t*   ppdOpenFile(const char* filename);
void          ppdClose(ppd_file_t* ppd);
ppd_option_t* ppdFindOption(ppd_file_t* ppd, const char* keyword);
ppd_size_t*   ppdPageSize(ppd_file_t* ppd, char* name);

#ifdef __cplusplus
}
#endif

#endif /* BSH_STUB_CUPS_PPD_H */
