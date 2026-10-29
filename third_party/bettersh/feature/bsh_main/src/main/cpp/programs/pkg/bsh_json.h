// bsh_json.h — pkg 用的极小 JSON 解析器
//
// 为什么不引第三方：我们只用它读两份自己生成的文档（服务器的 index.json、本地的
// installed.json），结构固定。一个 ~200 行的递归下降解析器比再拖一个库进来干净。
// 只读不写；不追求完整规范（不支持 \uXXXX 代理对合并、不支持注释、数字一律 double）。
#pragma once

#include <stddef.h>

typedef enum {
    BSH_JSON_NULL = 0,
    BSH_JSON_BOOL,
    BSH_JSON_NUM,
    BSH_JSON_STR,
    BSH_JSON_ARR,
    BSH_JSON_OBJ
} bsh_json_type;

typedef struct bsh_json bsh_json;
struct bsh_json {
    bsh_json_type type;
    double num;                 /* NUM / BOOL(0|1) */
    char* str;                  /* STR（本结构拥有） */
    bsh_json** items;           /* ARR */
    char** keys;                /* OBJ */
    bsh_json** vals;            /* OBJ */
    size_t n;                   /* ARR/OBJ 元素个数 */
};

/* 解析失败返回 NULL。text 里的转义会被解开，所以结果与入参无关。 */
bsh_json* bsh_json_parse(const char* text);

void bsh_json_free(bsh_json* v);

/* 对象取值；不是对象或没有该键返回 NULL。 */
bsh_json* bsh_json_get(const bsh_json* obj, const char* key);

/* 取值便捷函数（类型不对时给默认值）。 */
const char* bsh_json_str(const bsh_json* v, const char* def);
long bsh_json_int(const bsh_json* v, long def);

/* 数组访问。 */
size_t bsh_json_count(const bsh_json* v);
bsh_json* bsh_json_at(const bsh_json* v, size_t i);

/* 遍历对象：第 i 个键名（越界返回 NULL）。 */
const char* bsh_json_key(const bsh_json* obj, size_t i);
