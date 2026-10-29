// plugin_manager.cpp — 渲染器注册表（按 toplevelId 索引）
#include "plugin_manager.h"

#include <native_window/external_window.h>

#undef LOG_TAG
#define LOG_TAG "WaymonyPlugin"
#include <hilog/log.h>

PluginManager* PluginManager::GetInstance() {
    static PluginManager s;
    return &s;
}

bool PluginManager::CreateRenderer(uint32_t toplevelId, uint64_t surfaceId, int w, int h) {
    std::lock_guard<std::mutex> lk(mu_);
    // 已存在（窗口重建/重复回调）：先回收
    auto it = renderers_.find(toplevelId);
    if (it != renderers_.end()) {
        it->second->Shutdown();
        renderers_.erase(it);
    }

    OHNativeWindow* window = nullptr;
    int32_t rc = OH_NativeWindow_CreateNativeWindowFromSurfaceId((uint64_t)surfaceId, &window);
    if (rc != 0 || !window) {
        OH_LOG_ERROR(LOG_APP, "CreateNativeWindowFromSurfaceId failed tl=%{public}u surf=%{public}llu rc=%{public}d",
                     toplevelId, (unsigned long long)surfaceId, rc);
        return false;
    }

    auto renderer = std::make_unique<EglRenderer>();
    renderer->SetToplevelId(toplevelId);
    if (!renderer->Init(window, w, h)) {
        OH_LOG_ERROR(LOG_APP, "EglRenderer::Init failed tl=%{public}u", toplevelId);
        OH_NativeWindow_DestroyNativeWindow(window);
        return false;
    }
    renderers_[toplevelId] = std::move(renderer);
    OH_LOG_INFO(LOG_APP, "renderer created tl=%{public}u surfaceId=%{public}llu %{public}dx%{public}d",
                toplevelId, (unsigned long long)surfaceId, w, h);
    return true;
}

void PluginManager::ResizeRenderer(uint32_t toplevelId, int w, int h) {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = renderers_.find(toplevelId);
    if (it != renderers_.end()) it->second->OnResize(w, h);
}

void PluginManager::DestroyRenderer(uint32_t toplevelId) {
    std::unique_ptr<EglRenderer> victim;
    {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = renderers_.find(toplevelId);
        if (it == renderers_.end()) return;
        victim = std::move(it->second);
        renderers_.erase(it);
    }
    // 锁外 Shutdown（join 渲染线程可能阻塞，避免死锁）
    victim->Shutdown();
    OH_LOG_INFO(LOG_APP, "renderer destroyed tl=%{public}u", toplevelId);
}

int PluginManager::GetRendererCount() {
    std::lock_guard<std::mutex> lk(mu_);
    return (int)renderers_.size();
}
