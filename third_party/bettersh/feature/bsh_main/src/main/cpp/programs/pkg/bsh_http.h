// bsh_http.h — pkg 用的最小 HTTPS 客户端（mbedTLS）
//
// 只需要"把 https://…/x 的内容取回来"这一件事：无重定向、无代理、无续传。
// 请求发 HTTP/1.0（服务器会带 Content-Length 并且发完就关连接），于是响应体不用处理
// chunked —— 这是刻意选的：少一条解析路径就少一处出错的地方。
#pragma once

#include <stddef.h>

/* 每收到一段响应体就回调一次；返回非 0 表示放弃（会中断传输）。 */
typedef int (*bsh_http_write_fn)(void* ctx, const unsigned char* buf, size_t len);

/* HTTPS GET。成功返回 0；失败返回负值，并把原因写进 err。 */
int bsh_http_get(const char* url, bsh_http_write_fn fn, void* ctx,
                 char* err, size_t errlen);

/* 便捷封装：取到内存（malloc 出来的，调用方 free）。 */
int bsh_http_get_mem(const char* url, char** out, size_t* outlen,
                     char* err, size_t errlen);

/* 便捷封装：落文件（先写 <path>.part，成功了再 rename，避免半截文件）。 */
int bsh_http_get_file(const char* url, const char* path,
                      char* err, size_t errlen);

/* 拆 https://host[:port]/path —— 给调用方拼相对 URL、打日志用。 */
int bsh_http_parse_url(const char* url,
                       char* host, size_t hostlen,
                       char* port, size_t portlen,
                       char* path, size_t pathlen);
