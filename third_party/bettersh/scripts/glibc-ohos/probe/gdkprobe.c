/* gdkprobe v2 —— 复现 GTK 那句失败调用，而不只是问"PNG 行不行"。
 *
 * GTK 原文：
 *   gtkiconhelper.c:495:ensure_surface_for_gicon: assertion failed:
 *     Failed to load /org/gtk/libgtk/icons/16x16/status/image-missing.png:
 *     Unrecognized image file format (gdk-pixbuf-error-quark, 3)
 *
 * 走三条不同的路，看哪一条会挂：
 *   ① 文件路径      gdk_pixbuf_new_from_file(png)
 *   ② gresource 路径 gdk_pixbuf_new_from_resource("/org/gtk/libgtk/icons/16x16/status/image-missing.png")
 *      （先 dlopen libgtk-3.so.0，让它把自己的 gresource 注册上）
 *   ③ 流式 loader    GdkPixbufLoader + write/close（GTK 加载图标走的就是这条）
 *
 * 编译：aarch64-linux-gnu-gcc -O2 -o gdkprobe gdkprobe.c -L$V \
 *        -l:libgdk_pixbuf-2.0.so.0 -l:libgobject-2.0.so.0 -l:libglib-2.0.so.0 -ldl
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef struct _GSList { void *data; struct _GSList *next; } GSList;
typedef struct _GError { unsigned int domain; int code; char *message; } GError;
typedef struct _GBytes GBytes;

extern void *gdk_pixbuf_new_from_file(const char *, GError **);
extern void *gdk_pixbuf_new_from_resource(const char *, GError **);
extern GSList *gdk_pixbuf_get_formats(void);
extern char *gdk_pixbuf_format_get_name(void *);
extern int gdk_pixbuf_format_is_disabled(void *);
extern char **gdk_pixbuf_format_get_extensions(void *);
extern char **gdk_pixbuf_format_get_mime_types(void *);
extern const char *gdk_pixbuf_get_file_info(const char *, int *, int *);
/* GdkPixbufLoader */
extern void *gdk_pixbuf_loader_new(void);
extern int gdk_pixbuf_loader_write(void *, const unsigned char *, unsigned long, GError **);
extern int gdk_pixbuf_loader_close(void *, GError **);
extern void *gdk_pixbuf_loader_get_pixbuf(void *);
/* glib */
extern void g_free(void *);
extern void g_error_free(GError *);

static void *gdk_h;

static void resolve(const char *name) {
    void *sym = dlsym(gdk_h, name);
    Dl_info info;
    if (sym && dladdr(sym, &info) && info.dli_fname)
        printf("      %-26s -> %s\n", name, info.dli_fname);
    else
        printf("      %-26s -> (未解析)\n", name);
}

static void show_err(const char *tag, GError *e) {
    printf("      %s: domain=%u code=%d msg=%s\n", tag, e ? e->domain : 0,
           e ? e->code : -1, (e && e->message) ? e->message : "(null)");
}

int main(int argc, char **argv) {
    const char *png = argc > 1 ? argv[1] : "/tmp/bsh_t.png";
    printf("=== gdkprobe v2 ===\n");
    setvbuf(stdout, NULL, _IONBF, 0);   /* 崩溃也要看得见前面的话 */

    gdk_h = dlopen("libgdk_pixbuf-2.0.so.0", RTLD_LAZY | RTLD_GLOBAL);
    if (!gdk_h) { printf("dlopen libgdk_pixbuf 失败: %s\n", dlerror()); return 3; }

    printf("[1] 库解析:\n");
    resolve("gdk_pixbuf_new_from_file");
    resolve("gdk_pixbuf_new_from_resource");

    printf("[2] 已注册 image format:\n");
    int n = 0;
    for (GSList *l = gdk_pixbuf_get_formats(); l; l = l->next) {
        void *f = l->data;
        char **ex = gdk_pixbuf_format_get_extensions(f);
        char **mi = gdk_pixbuf_format_get_mime_types(f);
        printf("      %-8s disabled=%d mime=[%s] ext=[%s]\n",
               gdk_pixbuf_format_get_name(f), gdk_pixbuf_format_is_disabled(f),
               (mi && mi[0]) ? mi[0] : "", (ex && ex[0]) ? ex[0] : "");
        n++;
    }
    printf("      共 %d 个\n", n);

    printf("[3] 文件路径 %s:\n", png);
    {
        GError *e = NULL;
        FILE *tf = fopen(png, "rb");
        long sz = 0;
        unsigned char head[8] = {0};
        if (tf) { fseek(tf, 0, SEEK_END); sz = ftell(tf); fseek(tf, 0, SEEK_SET);
                  fread(head, 1, 8, tf); fclose(tf); }
        printf("      文件大小=%ld 头8字节=%02x%02x%02x%02x%02x%02x%02x%02x\n",
               sz, head[0], head[1], head[2], head[3], head[4], head[5], head[6], head[7]);
        void *pb = gdk_pixbuf_new_from_file(png, &e);
        printf("      pixbuf=%p\n", pb);
        if (!pb) show_err("new_from_file 失败", e);
    }
    printf("[4] sniff: ");
    { int w = 0, h = 0; const char *f = gdk_pixbuf_get_file_info(png, &w, &h);
      printf("fmt=%s %dx%d\n", f ? f : "(null)", w, h); }

    printf("[5] dlopen libgtk-3.so.0（注册它的 gresource）:\n");
    void *gtk = dlopen("libgtk-3.so.0", RTLD_LAZY | RTLD_GLOBAL);
    printf("      gtk=%p err=%s\n", gtk, gtk ? "-" : dlerror());

    printf("[6] gresource: /org/gtk/libgtk/icons/16x16/status/image-missing.png\n");
    {
        GError *e = NULL;
        void *pb = gdk_pixbuf_new_from_resource(
            "/org/gtk/libgtk/icons/16x16/status/image-missing.png", &e);
        printf("      pixbuf=%p\n", pb);
        if (!pb) show_err("new_from_resource 失败", e);
    }

    printf("[7] 流式 GdkPixbufLoader（GTK 加载图标的真实路径）:\n");
    {
        FILE *tf = fopen(png, "rb");
        if (!tf) { printf("      打不开 %s\n", png); }
        else {
            unsigned char buf[65536];
            size_t r = fread(buf, 1, sizeof buf, tf);
            fclose(tf);
            GError *e = NULL;
            void *ld = gdk_pixbuf_loader_new();
            int ok = gdk_pixbuf_loader_write(ld, buf, r, &e);
            printf("      write=%d\n", ok);
            if (!ok) show_err("write 失败", e);
            e = NULL;
            ok = gdk_pixbuf_loader_close(ld, &e);
            printf("      close=%d pixbuf=%p\n", ok, gdk_pixbuf_loader_get_pixbuf(ld));
            if (!ok) show_err("close 失败", e);
        }
    }
    printf("=== DONE ===\n");
    return 0;
}
