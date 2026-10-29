// bsh_json.c — pkg 用的极小 JSON 解析器（见 bsh_json.h 的取舍说明）
#include "bsh_json.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char* p;
    int depth;
} cur_t;

#define BSH_JSON_MAX_DEPTH 64

static void skip_ws(cur_t* c)
{
    while (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')
        c->p++;
}

static bsh_json* parse_value(cur_t* c);

static bsh_json* node_new(bsh_json_type t)
{
    bsh_json* v = calloc(1, sizeof *v);
    if (v)
        v->type = t;
    return v;
}

static int hex4(const char* p, unsigned* out)
{
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char ch = p[i];
        v <<= 4;
        if (ch >= '0' && ch <= '9')      v |= (unsigned)(ch - '0');
        else if (ch >= 'a' && ch <= 'f') v |= (unsigned)(ch - 'a' + 10);
        else if (ch >= 'A' && ch <= 'F') v |= (unsigned)(ch - 'A' + 10);
        else return -1;
    }
    *out = v;
    return 0;
}

/* 解析字符串字面量（调用时 *c->p 是开头的引号），返回 malloc 出来的串 */
static char* parse_string(cur_t* c)
{
    if (*c->p != '"')
        return NULL;
    c->p++;
    size_t cap = 32, len = 0;
    char* out = malloc(cap);
    if (!out)
        return NULL;
    while (*c->p && *c->p != '"') {
        unsigned char ch = (unsigned char)*c->p;
        if (len + 8 >= cap) {
            cap *= 2;
            char* np = realloc(out, cap);
            if (!np) { free(out); return NULL; }
            out = np;
        }
        if (ch == '\\') {
            c->p++;
            switch (*c->p) {
            case '"':  out[len++] = '"';  c->p++; break;
            case '\\': out[len++] = '\\'; c->p++; break;
            case '/':  out[len++] = '/';  c->p++; break;
            case 'b':  out[len++] = '\b'; c->p++; break;
            case 'f':  out[len++] = '\f'; c->p++; break;
            case 'n':  out[len++] = '\n'; c->p++; break;
            case 'r':  out[len++] = '\r'; c->p++; break;
            case 't':  out[len++] = '\t'; c->p++; break;
            case 'u': {
                unsigned cp;
                if (hex4(c->p + 1, &cp) != 0) { free(out); return NULL; }
                c->p += 5;
                /* 只处理 BMP：编成 UTF-8；代理对不合并（我们自己的文档里不会有） */
                if (cp < 0x80) {
                    out[len++] = (char)cp;
                } else if (cp < 0x800) {
                    out[len++] = (char)(0xC0 | (cp >> 6));
                    out[len++] = (char)(0x80 | (cp & 0x3F));
                } else {
                    out[len++] = (char)(0xE0 | (cp >> 12));
                    out[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    out[len++] = (char)(0x80 | (cp & 0x3F));
                }
                break;
            }
            default:
                free(out);
                return NULL;
            }
        } else {
            out[len++] = (char)ch;
            c->p++;
        }
    }
    if (*c->p != '"') { free(out); return NULL; }
    c->p++;
    out[len] = 0;
    return out;
}

static bsh_json* parse_array(cur_t* c)
{
    bsh_json* v = node_new(BSH_JSON_ARR);
    if (!v)
        return NULL;
    c->p++;   /* '[' */
    skip_ws(c);
    if (*c->p == ']') { c->p++; return v; }
    for (;;) {
        bsh_json* item = parse_value(c);
        if (!item)
            goto fail;
        bsh_json** ni = realloc(v->items, (v->n + 1) * sizeof *ni);
        if (!ni) { bsh_json_free(item); goto fail; }
        v->items = ni;
        v->items[v->n++] = item;
        skip_ws(c);
        if (*c->p == ',') { c->p++; skip_ws(c); continue; }
        if (*c->p == ']') { c->p++; return v; }
        goto fail;
    }
fail:
    bsh_json_free(v);
    return NULL;
}

static bsh_json* parse_object(cur_t* c)
{
    bsh_json* v = node_new(BSH_JSON_OBJ);
    if (!v)
        return NULL;
    c->p++;   /* '{' */
    skip_ws(c);
    if (*c->p == '}') { c->p++; return v; }
    for (;;) {
        char* k = parse_string(c);
        if (!k)
            goto fail;
        skip_ws(c);
        if (*c->p != ':') { free(k); goto fail; }
        c->p++;
        skip_ws(c);
        bsh_json* val = parse_value(c);
        if (!val) { free(k); goto fail; }
        char** nk = realloc(v->keys, (v->n + 1) * sizeof *nk);
        bsh_json** nv = nk ? realloc(v->vals, (v->n + 1) * sizeof *nv) : NULL;
        if (!nk || !nv) { free(k); bsh_json_free(val); goto fail; }
        v->keys = nk;
        v->vals = nv;
        v->keys[v->n] = k;
        v->vals[v->n] = val;
        v->n++;
        skip_ws(c);
        if (*c->p == ',') { c->p++; skip_ws(c); continue; }
        if (*c->p == '}') { c->p++; return v; }
        goto fail;
    }
fail:
    bsh_json_free(v);
    return NULL;
}

static bsh_json* parse_value(cur_t* c)
{
    skip_ws(c);
    if (c->depth++ > BSH_JSON_MAX_DEPTH || !*c->p) {
        c->depth--;
        return NULL;
    }
    bsh_json* v = NULL;
    if (*c->p == '{') {
        v = parse_object(c);
    } else if (*c->p == '[') {
        v = parse_array(c);
    } else if (*c->p == '"') {
        char* s = parse_string(c);
        if (s) {
            v = node_new(BSH_JSON_STR);
            if (v)
                v->str = s;
            else
                free(s);
        }
    } else if (strncmp(c->p, "true", 4) == 0) {
        v = node_new(BSH_JSON_BOOL);
        if (v) { v->num = 1; c->p += 4; }
    } else if (strncmp(c->p, "false", 5) == 0) {
        v = node_new(BSH_JSON_BOOL);
        if (v) { v->num = 0; c->p += 5; }
    } else if (strncmp(c->p, "null", 4) == 0) {
        v = node_new(BSH_JSON_NULL);
        if (v) c->p += 4;
    } else {
        char* end = NULL;
        double d = strtod(c->p, &end);
        if (end && end != c->p) {
            v = node_new(BSH_JSON_NUM);
            if (v) { v->num = d; c->p = end; }
        }
    }
    c->depth--;
    return v;
}

bsh_json* bsh_json_parse(const char* text)
{
    if (!text)
        return NULL;
    cur_t c = { text, 0 };
    bsh_json* v = parse_value(&c);
    if (!v)
        return NULL;
    skip_ws(&c);
    if (*c.p != 0) {          /* 后面还有垃圾 → 判为解析失败 */
        bsh_json_free(v);
        return NULL;
    }
    return v;
}

void bsh_json_free(bsh_json* v)
{
    if (!v)
        return;
    free(v->str);
    for (size_t i = 0; i < v->n; i++) {
        if (v->items)
            bsh_json_free(v->items[i]);
        if (v->keys)
            free(v->keys[i]);
        if (v->vals)
            bsh_json_free(v->vals[i]);
    }
    free(v->items);
    free(v->keys);
    free(v->vals);
    free(v);
}

bsh_json* bsh_json_get(const bsh_json* obj, const char* key)
{
    if (!obj || obj->type != BSH_JSON_OBJ || !key)
        return NULL;
    for (size_t i = 0; i < obj->n; i++)
        if (strcmp(obj->keys[i], key) == 0)
            return obj->vals[i];
    return NULL;
}

const char* bsh_json_str(const bsh_json* v, const char* def)
{
    if (!v || v->type != BSH_JSON_STR || !v->str)
        return def;
    return v->str;
}

long bsh_json_int(const bsh_json* v, long def)
{
    if (!v || (v->type != BSH_JSON_NUM && v->type != BSH_JSON_BOOL))
        return def;
    return (long)v->num;
}

size_t bsh_json_count(const bsh_json* v)
{
    if (!v)
        return 0;
    return v->n;
}

bsh_json* bsh_json_at(const bsh_json* v, size_t i)
{
    if (!v || i >= v->n)
        return NULL;
    if (v->type == BSH_JSON_ARR)
        return v->items[i];
    if (v->type == BSH_JSON_OBJ)
        return v->vals[i];
    return NULL;
}

const char* bsh_json_key(const bsh_json* obj, size_t i)
{
    if (!obj || obj->type != BSH_JSON_OBJ || i >= obj->n)
        return NULL;
    return obj->keys[i];
}
