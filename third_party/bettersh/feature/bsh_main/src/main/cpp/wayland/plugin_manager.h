#pragma once
// plugin_manager.h — XComponent 多实例管理
//
// 每个 toplevel 窗口对应一个 ArkUI SubWindow，其中放一个 XComponent；
// ArkTS 侧通过 XComponentController.onSurfaceCreated 拿到 surfaceId，
// 调用 createRenderer(toplevelId, surfaceId, w, h) 绑定渲染器。
#include <memory>
#include <mutex>
#include <unordered_map>

#include "egl_renderer.h"

class PluginManager {
public:
    static PluginManager* GetInstance();

    // surfaceId → OHNativeWindow → EglRenderer
    bool CreateRenderer(uint32_t toplevelId, uint64_t surfaceId, int w, int h);
    void ResizeRenderer(uint32_t toplevelId, int w, int h);
    void DestroyRenderer(uint32_t toplevelId);
    int GetRendererCount();

private:
    PluginManager() = default;
    std::mutex mu_;
    std::unordered_map<uint32_t, std::unique_ptr<EglRenderer>> renderers_;
};
