// qtwl-demo — 最小 Qt6 Wayland 客户端（QWidget raster → wl_shm）
#include <QApplication>
#include <QWidget>
#include <QLabel>
#include <QPushButton>
#include <QVBoxLayout>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>

#include <wayland-client.h>

int main(int argc, char** argv)
{
    QApplication app(argc, argv);
    app.setApplicationName("qtwl-demo");
    app.setApplicationDisplayName("QtWayland Demo (Waymony)");

    QWidget win;
    win.setWindowTitle("Qt6 Wayland Demo on Waymony");
    win.resize(480, 320);

    auto* layout = new QVBoxLayout(&win);
    auto* label = new QLabel("Hello from Qt 6.12 via WAYLAND_TCP", &win);
    label->setAlignment(Qt::AlignCenter);
    auto* btn = new QPushButton("Click me", &win);

    layout->addWidget(label);
    layout->addWidget(btn);
    QObject::connect(btn, &QPushButton::clicked, [&] {
        label->setText("Button clicked! Wayland input works.");
    });

    win.show();
    return app.exec();
}
