#pragma once
// egl_renderer.h — 每窗口 EGL/GLES 渲染器
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <native_window/external_window.h>

#include <atomic>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>

class EglRenderer {
public:
    ~EglRenderer() { Shutdown(); }

    // 绑定渲染源 toplevel id（wl_shm 帧缓冲）
    void SetToplevelId(uint32_t id) { toplevelId_ = id; }
    uint32_t GetToplevelId() const { return toplevelId_; }

    // 初始化：OHNativeWindow 来自 OH_NativeWindow_CreateNativeWindowFromSurfaceId
    bool Init(OHNativeWindow* window, int width, int height);
    void OnResize(int w, int h);
    void Shutdown();

private:
    void RenderLoop();

    OHNativeWindow* window_ = nullptr;
    std::atomic<int> width_{0};
    std::atomic<int> height_{0};
    std::atomic<uint32_t> toplevelId_{0};

    std::atomic<bool> running_{false};
    std::thread th_;

    EGLDisplay eglDisp_ = EGL_NO_DISPLAY;
    EGLContext eglCtx_ = EGL_NO_CONTEXT;
    EGLSurface eglSurf_ = EGL_NO_SURFACE;
    GLuint prog_ = 0;
    GLuint vbo_ = 0;
    GLuint tex_ = 0;
};
