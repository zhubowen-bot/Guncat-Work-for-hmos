// egl_renderer.cpp — 每窗口渲染循环（wl_shm → GL 纹理 → eglSwapBuffers）
#include "egl_renderer.h"
#include "wayland_server.h"
#include "../common/bsh_paths.h"

#include <unistd.h>
#include <cstdio>
#include <cstdint>

#undef LOG_TAG
#define LOG_TAG "WaymonyEgl"
#include <hilog/log.h>

static const char* kVS = R"(#version 300 es
layout(location=0) in vec2 aPos;
layout(location=1) in vec2 aUV;
out vec2 vUV;
void main(){ vUV = aUV; gl_Position = vec4(aPos, 0, 1); }
)";

// wl_shm ARGB8888 内存序 = BGRA little-endian，上传为 GL_RGBA 后 .bgra 还原
static const char* kFS = R"(#version 300 es
precision mediump float;
in vec2 vUV; out vec4 oColor;
uniform sampler2D uTex;
void main(){ oColor = texture(uTex, vUV).bgra; }
)";

static GLuint CompileShader(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "shader compile failed: %{public}s", log);
    }
    return s;
}

bool EglRenderer::Init(OHNativeWindow* w, int width, int height) {
    if (running_.load()) Shutdown();

    window_ = w;
    width_ = width;
    height_ = height;

    eglDisp_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisp_ == EGL_NO_DISPLAY) return false;
    EGLint major = 0, minor = 0;
    if (!eglInitialize(eglDisp_, &major, &minor)) return false;

    EGLConfig cfg = nullptr;
    EGLint nCfg = 0;
    EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE,
    };
    eglChooseConfig(eglDisp_, attrs, &cfg, 1, &nCfg);
    if (nCfg < 1) return false;

    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    eglCtx_ = eglCreateContext(eglDisp_, cfg, EGL_NO_CONTEXT, ctxAttrs);
    eglSurf_ = eglCreateWindowSurface(eglDisp_, cfg,
                                      reinterpret_cast<EGLNativeWindowType>(window_), nullptr);
    if (eglSurf_ == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "eglCreateWindowSurface failed 0x%{public}x", eglGetError());
        return false;
    }

    running_ = true;
    OH_LOG_INFO(LOG_APP, "init: this=%{public}p tl=%{public}u running=%{public}d",
                (void*)this, toplevelId_.load(), running_.load() ? 1 : 0);
    th_ = std::thread(&EglRenderer::RenderLoop, this);
    return true;
}


/* 渲染统计落**文件**而不是 hilog —— hilog 对高频日志会限流/丢弃，
 * 而渲染循环是 60fps（见 build/vscode/STATUS.md §45：我连着三轮拿"hilog 里没有 X"
 * 当"没发生"的证据，而那个通道本身会丢样本）。文件不会丢。 */
static void RenderStats(uint32_t tl, uint64_t iters, uint64_t taken, uint64_t swaps,
                        int fw, int fh, bool got, EGLDisplay dpy, EGLSurface surf)
{
    /* 连 EGL surface 的**实际尺寸**一起落盘：`resizeRenderer` 只改了 glViewport 用的
     * width_/height_，没重建 surface —— 若 surface 一直是初始的 640x480、而 viewport 是
     * 2400x1540，那就是明确错配（STATUS §47.3 B）。 */
    EGLint sw = -1, sh = -1;
    if (dpy != EGL_NO_DISPLAY && surf != EGL_NO_SURFACE) {
        eglQuerySurface(dpy, surf, EGL_WIDTH, &sw);
        eglQuerySurface(dpy, surf, EGL_HEIGHT, &sh);
    }
    char path[512];
    snprintf(path, sizeof path, "%s/render-stats.txt", bsh_sysroot());
    FILE* f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "tl=%u iters=%llu taken=%llu swaps=%llu got=%d frame=%dx%d surface=%dx%d err=0x%x\n",
            tl, (unsigned long long)iters, (unsigned long long)taken,
            (unsigned long long)swaps, got ? 1 : 0, fw, fh, sw, sh, (unsigned)eglGetError());
    fclose(f);
}

void EglRenderer::RenderLoop() {
    /* "窗口是黑的、而且 takeLatest 一次都没打"（STATUS §39）—— 需要在**循环之前**
     * 就把路标铺满，才能分辨"线程没起来 / 卡在哪一步 / 卡在 TakeLatestFrame"。 */
    OH_LOG_INFO(LOG_APP, "renderLoop: enter this=%{public}p tl=%{public}u running=%{public}d",
                (void*)this, toplevelId_.load(), running_.load() ? 1 : 0);
    if (!eglMakeCurrent(eglDisp_, eglSurf_, eglSurf_, eglCtx_)) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed 0x%{public}x", eglGetError());
        return;
    }
    OH_LOG_INFO(LOG_APP, "renderLoop: makeCurrent ok");

    GLuint vs = CompileShader(GL_VERTEX_SHADER, kVS);
    GLuint fs = CompileShader(GL_FRAGMENT_SHADER, kFS);
    prog_ = glCreateProgram();
    glAttachShader(prog_, vs);
    glAttachShader(prog_, fs);
    glLinkProgram(prog_);

    float quad[] = {
        -1, -1, 0, 1,   1, -1, 1, 1,   -1, 1, 0, 0,
         1, -1, 1, 1,   1,  1, 1, 0,   -1, 1, 0, 0,
    };
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

    glGenTextures(1, &tex_);
    glBindTexture(GL_TEXTURE_2D, tex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    OH_LOG_INFO(LOG_APP, "renderLoop: gl setup ok -> enter while");

    std::vector<uint8_t> px;
    int fw = 0, fh = 0;
    uint64_t iters = 0, taken = 0, swaps = 0;

    RenderStats(toplevelId_.load(), 0, 0, 0, 0, 0, false, eglDisp_, eglSurf_);   /* 进循环前先落一条 */
    while (running_.load()) {
        iters++;
        uint32_t tlId = toplevelId_.load();
        bool got = false;
        if (tlId != 0) got = WaylandServer::GetInstance()->TakeLatestFrame(tlId, px, fw, fh);
        /* 渲染线程有没有拿到帧（TakeLatestFrame 依赖 tl->dirty 被 commit 置位、被这里清掉）。
         * "窗口是黑的"要么是这里一帧没拿到，要么是拿到了但内容是黑 —— 配合
         * wayland_server.cpp 里那条 frame 日志就能分开。只打前 40 次。 */
        {
            static int s_takeLog = 0;
            if (s_takeLog < 40) {
                s_takeLog++;
                OH_LOG_INFO(LOG_APP, "takeLatest tl=%{public}u got=%{public}d %{public}dx%{public}d",
                            tlId, got ? 1 : 0, fw, fh);
            }
        }
        if (got && fw > 0 && fh > 0) {
            glBindTexture(GL_TEXTURE_2D, tex_);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, fw, fh, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, px.data());
        }

        const int vpW = width_.load();
        const int vpH = height_.load();
        /* ★ 只在**拿到新帧**时才重绘 + swap。
         * 原来是无条件 60fps（每帧上传 3.84MB 纹理 + 全屏 draw + swap），
         * 旧窗口的循环会一直烧 EGL/CPU/带宽；新窗口再来一个就供不上帧 ——
         * 实测症状正是"每个 app 会话里只有第一次跑 VS Code 成功(taken≈35+)，
         * 之后全是 taken=1"。详见 build/vscode/STATUS.md §72。 */
        if (!got) { usleep(16667); continue; }
        glViewport(0, 0, vpW, vpH);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);

        glUseProgram(prog_);
        glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (void*)8);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex_);
        glUniform1i(glGetUniformLocation(prog_, "uTex"), 0);
        glDrawArrays(GL_TRIANGLES, 0, 6);

        eglSwapBuffers(eglDisp_, eglSurf_);
        swaps++;
        if (got) {
            taken++;
            /* 只在这里记"渲染器真正取走的那一帧"黑不黑。§39 量的是 commit 时存下来的像素，
             * 而 taken=1 说明真正取走的只有一帧 —— 两者不一定是同一帧（STATUS §48.2）。 */
            size_t nz = 0, n = px.size();
            for (size_t i = 0; i + 3 < n && i < 65536; i += 4)
                if (px[i] || px[i + 1] || px[i + 2]) nz++;
            char p2[512];
            snprintf(p2, sizeof p2, "%s/render-stats.txt", bsh_sysroot());
            FILE* f2 = fopen(p2, "a");
            if (f2) {
                fprintf(f2, "FRAME tl=%u size=%dx%d bytes=%zu nz16K=%zu b0..3=%02x%02x%02x%02x\n",
                        toplevelId_.load(), fw, fh, n, nz,
                        n ? px[0] : 0, n > 1 ? px[1] : 0, n > 2 ? px[2] : 0, n > 3 ? px[3] : 0);
                fclose(f2);
            }
        }
        usleep(16667);  // ~60fps 轮询
    }
}

void EglRenderer::OnResize(int w, int h) {
    width_ = w;
    height_ = h;
}

void EglRenderer::Shutdown() {
    /* 谁在关它？（STATUS §42）`renderer destroyed` 计数是 0，说明不是 DestroyRenderer ——
     * 另外两个调用点（析构、CreateRenderer 的静默回收分支）都不打日志。
     * 这里把返回地址打出来，落地后可以直接对着 libentry.so 符号化，
     * 一次就能指名道姓。必须在早退之前打。 */
    OH_LOG_INFO(LOG_APP, "Shutdown: running=%{public}d caller=%{public}p",
                running_.load() ? 1 : 0, __builtin_return_address(0));
    if (!running_.exchange(false)) return;
    if (th_.joinable()) th_.join();
    if (eglDisp_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(eglDisp_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (eglSurf_ != EGL_NO_SURFACE) eglDestroySurface(eglDisp_, eglSurf_);
        if (eglCtx_ != EGL_NO_CONTEXT) eglDestroyContext(eglDisp_, eglCtx_);
        eglTerminate(eglDisp_);
        eglDisp_ = EGL_NO_DISPLAY;
        eglCtx_ = EGL_NO_CONTEXT;
        eglSurf_ = EGL_NO_SURFACE;
    }
    window_ = nullptr;
    prog_ = 0;
    vbo_ = 0;
    tex_ = 0;
}
