/* programs/gtkprobe/main.c — GTK3 窗口探针
 *
 * 目的只有一个：**GTK3 能不能在我们的合成器（feature/bsh_main 里那个 wl_display）上
 * 把窗口拉起来**。它是将来判断"能不能跑 Electron 这类真实 GUI 应用"的前置 ——
 * GTK3 起不来，Electron 一定起不来（桌面版 VS Code 就是 Electron）。
 *
 * 所以刻意什么都不做：建窗、放一行字、显示、跑主循环，并在 stdout 打几行状态，
 * 方便在设备上不开图形也能看出它走到哪一步（合成器连上了没有、窗口拿到 configure 没有）。
 *
 * 编法与依赖见 scripts/build_gtk.sh（GTK3 只编 wayland 后端，因为这台设备没有 X11）。 */
#include <gtk/gtk.h>

static gboolean on_timeout(gpointer win)
{
    /* 主循环真的转起来了才有这行；顺便给一个"能自己退出"的开关，
     * 免得自动化测试里还要去点窗口。 */
    g_print("gtkprobe: 主循环在转（窗口 %p 已显示）\n", win);
    return G_SOURCE_REMOVE;
}

static void on_activate(GtkApplication* app, gpointer user_data)
{
    (void)user_data;
    GtkWidget* win = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(win), "GTK3 on BetterSH");
    gtk_window_set_default_size(GTK_WINDOW(win), 420, 260);

    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(box), 16);
    GtkWidget* label = gtk_label_new("Gtk+3 says hello\n（这句话是 GTK 画出来的）");
    gtk_box_pack_start(GTK_BOX(box), label, TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(win), box);
    gtk_widget_show_all(win);

    g_print("gtkprobe: activate —— GDK 后端=%s，窗口已建\n",
            G_OBJECT_TYPE_NAME(gdk_display_get_default()));
    g_timeout_add(500, on_timeout, win);
}

int main(int argc, char** argv)
{
    /* 强制 wayland 后端：我们没编 X11 后端，但把话说死更利于排查
     * （否则 GDK 会先试 x11 再回落，日志里会多一段没意义的报错）。 */
    g_setenv("GDK_BACKEND", "wayland", TRUE);
    g_print("gtkprobe: GTK %d.%d.%d，WAYLAND_DISPLAY=%s\n",
            gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version(),
            g_getenv("WAYLAND_DISPLAY") ? g_getenv("WAYLAND_DISPLAY") : "(未设)");

    GtkApplication* app = gtk_application_new("com.yiyan.bettersh.gtkprobe",
                                             G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int st = g_application_run(G_APPLICATION(app), argc, argv);
    g_print("gtkprobe: 退出，status=%d\n", st);
    g_object_unref(app);
    return st;
}
