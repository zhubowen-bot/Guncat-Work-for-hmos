// bshutil/ui_bus.cpp — C++ → ArkTS 事件通道的实现
//
// 用 napi_threadsafe_function:shell 线程调 bsh_ui_notify,事件在 ArkTS 的 UI
// 线程上执行。用 nonblocking 投递 —— 事件是"通知",不该让 shell 线程等。
//
// 多窗口:订阅按**会话号 sid** 登记(见 ui_bus.h)。通知走广播(全局设置对所有窗口
// 一起生效),请求走精确匹配(必须弹在发起命令的那个窗口里)。
#include "ui_bus.h"
#include "bsh_cfg.h"

#include <cstdio>
#include <cstring>
#include <string>

#undef LOG_TAG
#define LOG_TAG "BSH_UiBus"
#include <hilog/log.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

namespace {

/* 按会话号登记的接收方:0 = 主窗口的 bsh 会话,>0 = 新开的 tab。
 * 从 UI 线程写、从 shell/服务端线程读,所以整个 map 由 g_mu 保护
 * (以前是一个裸全局,单订阅时侥幸没出事)。 */
std::mutex g_mu;
std::map<int, napi_threadsafe_function> g_subs;

struct UiEvent {
    std::string json;
};

/* 一条"等回执"的请求(native 阻塞在这上面,ArkTS 调 bsh_ui_resolve 唤醒) */
struct Pending {
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;
    std::string result;
};

std::mutex g_reqMu;
std::map<int, std::shared_ptr<Pending>> g_pending;
std::atomic<int> g_nextReqId{1};

void UiTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    auto* ev = static_cast<UiEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, arg;
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, ev->json.c_str(), NAPI_AUTO_LENGTH, &arg);
        napi_call_function(env, undef, jsCb, 1, &arg, nullptr);
    }
    delete ev;
}

/* tsfn 被释放(ArkTS 侧销毁)时把这个 sid 的登记项摘掉,后续 notify 自然跳过它。
 * sid 经 thread_finalize_data 传进来 —— 那个字段除了转交给这里没别的用途
 * (context 那个字段另有用处:它是 call_js_cb 的第三个参数)。 */
void UiTsfnFinalize(napi_env, void* data, void* /*hint*/) {
    const int sid = (int)(intptr_t)data;
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_subs.find(sid);
    if (it != g_subs.end()) g_subs.erase(it);
}

/* 取某个 sid 的 tsfn(调用方持 g_mu)。找不到返回 nullptr。 */
napi_threadsafe_function SubOf(int sid) {
    auto it = g_subs.find(sid);
    return it == g_subs.end() ? nullptr : it->second;
}

/* 往一个 tsfn 投事件(不持锁调用 —— 投递本身会走 napi 内部锁,别和 g_mu 嵌套)。 */
bool PostTo(napi_threadsafe_function fn, const std::string& json) {
    if (!fn) return false;
    auto* ev = new UiEvent{json};
    napi_status st = napi_call_threadsafe_function(fn, ev, napi_tsfn_nonblocking);
    if (st != napi_ok) {
        delete ev;
        OH_LOG_WARN(LOG_APP, "ui notify failed: %{public}d", (int)st);
        return false;
    }
    return true;
}

}  // namespace

extern "C" int bsh_ui_subscribe(int sid, napi_env env, napi_value cb) {
    /* 同一个 sid 重复注册(页面重载):先释放旧的,否则旧 tsfn 会一直挂在 map 里,
     * 事件会被投递两次。释放必须在锁外做 —— release 会触发 finalize,那里要拿 g_mu。 */
    napi_threadsafe_function old = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        old = SubOf(sid);
        if (old) g_subs.erase(sid);
    }
    if (old) napi_release_threadsafe_function(old, napi_tsfn_release);

    napi_value resName;
    napi_create_string_utf8(env, "BetterSH_UiBus", NAPI_AUTO_LENGTH, &resName);
    napi_threadsafe_function fn = nullptr;
    napi_status st = napi_create_threadsafe_function(
        env, cb, nullptr, resName,
        0,                          /* max_queue_size:不限,事件很稀疏 */
        1,                          /* initial_thread_count */
        (void*)(intptr_t)sid, UiTsfnFinalize, nullptr,   /* finalize_data = sid */
        UiTsfnCallJs, &fn);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "create tsfn failed: %{public}d", (int)st);
        return -1;
    }
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_subs[sid] = fn;
    }
    OH_LOG_INFO(LOG_APP, "ui bus subscribed sid=%{public}d", sid);
    /* 订阅成功把当前配置推给**这一个**窗口:ArkTS 侧要拿初始值(窗口缩放、右键行为)
     * 才不用另外查 —— 配置存在 native 的 bettersh.conf 里,UI 自己读不到。
     * 这里刻意只推给自己(而不是 bsh_ui_notify 那样广播):新窗口刚起来,别的窗口
     * 早就拿到过这些值了,再广播一遍只会让它们重复应用一次设置。 */
    char json[80];
    snprintf(json, sizeof json, "{\"op\":\"scale\",\"value\":%.2f}",
             bsh_cfg_win_scale());
    PostTo(fn, json);
    snprintf(json, sizeof json, "{\"op\":\"rightclick\",\"mode\":\"%s\"}",
             bsh_cfg_right_click() ? "smart" : "menu");
    PostTo(fn, json);
    return 0;
}

extern "C" int bsh_ui_unsubscribe(int sid) {
    napi_threadsafe_function fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        fn = SubOf(sid);
        if (fn) g_subs.erase(sid);
    }
    if (!fn) return -1;
    napi_release_threadsafe_function(fn, napi_tsfn_release);
    return 0;
}

extern "C" int bsh_ui_notify(const char* json) {
    if (!json) return -1;
    /* 广播:keys/win-scale/right-click 是全局设置,所有窗口都该跟着变。
     * 先把 tsfn 抄出来再投递,不持着 g_mu 走 napi。 */
    std::vector<napi_threadsafe_function> fns;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        for (auto& kv : g_subs) fns.push_back(kv.second);
    }
    if (fns.empty()) return -1;
    bool any = false;
    for (napi_threadsafe_function fn : fns)
        if (PostTo(fn, json)) any = true;
    return any ? 0 : -1;
}

extern "C" int bsh_ui_request(int sid, const char* json, char* out, size_t cap,
                              int timeout_ms) {
    if (!json || !out || cap == 0) return -1;
    napi_threadsafe_function fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        fn = SubOf(sid);
    }
    if (!fn) return -1;

    int id = g_nextReqId.fetch_add(1);
    auto p = std::make_shared<Pending>();
    {
        std::lock_guard<std::mutex> lk(g_reqMu);
        g_pending[id] = p;
    }

    /* 在事件 JSON 里补一个 "req":<id>,ArkTS 回填时带回来。
     * 注意只加字段、不加右括号 —— 原来那个 } 还在后面。 */
    std::string body(json);
    size_t brace = body.rfind('}');
    if (brace == std::string::npos) {   // 调用方都应传完整 JSON,走到这说明用错了
        std::lock_guard<std::mutex> lk(g_reqMu);
        g_pending.erase(id);
        return -1;
    }
    char extra[32];
    snprintf(extra, sizeof extra, ",\"req\":%d", id);
    body.insert(brace, extra);

    auto* ev = new UiEvent{body};
    napi_status st = napi_call_threadsafe_function(fn, ev, napi_tsfn_nonblocking);
    if (st != napi_ok) {
        delete ev;
        std::lock_guard<std::mutex> lk(g_reqMu);
        g_pending.erase(id);
        return -1;
    }

    /* 等 ArkTS 回执。picker 这类要用户操作,超时给得长一些(调用方定)。 */
    std::unique_lock<std::mutex> lk(p->mu);
    bool ok = p->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                             [&] { return p->done; });
    if (ok) snprintf(out, cap, "%s", p->result.c_str());
    lk.unlock();
    {
        std::lock_guard<std::mutex> g(g_reqMu);
        g_pending.erase(id);
    }
    if (!ok) OH_LOG_WARN(LOG_APP, "ui request %{public}d timeout", id);
    return ok ? 0 : -1;
}

extern "C" int bsh_ui_resolve(int req_id, const char* result) {
    std::shared_ptr<Pending> p;
    {
        std::lock_guard<std::mutex> lk(g_reqMu);
        auto it = g_pending.find(req_id);
        if (it == g_pending.end()) return -1;
        p = it->second;
    }
    {
        std::lock_guard<std::mutex> lk(p->mu);
        p->result = result ? result : "";
        p->done = true;
    }
    p->cv.notify_all();
    return 0;
}
