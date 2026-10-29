// bshutil/ui_bus.h — C++ → ArkTS 的单向事件通道
//
// bshutil 有些子命令自己做不到(native 起不了系统选择器、也管不了 ArkUI 的
// 状态),需要请 ArkTS 代劳。这里就是那条通道:ArkTS 在页面里注册一个接收方
// (bshUiSubscribe),native 侧 bsh_ui_notify 推一个 JSON 事件过去。
//
// 刻意做成**单向**:native 不等结果。请求类动作(如 picker)拿到的目录会在
// ArkTS 那侧拷进沙箱,用户之后自己 `ls` 验证 —— 这样不会把 shell 线程卡住。
#pragma once

#include <napi/native_api.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ArkTS 注册接收方,按**会话号 sid** 登记(0 = 主窗口的 bsh 会话,>0 = 新开的 tab)。
 * 同一个 sid 重复注册会替换旧的。返回 0 成功。 */
int bsh_ui_subscribe(int sid, napi_env env, napi_value cb);

/* 某个会话的窗口没了(页面销毁)时注销,免得事件打进已释放的 tsfn。
 * 顺带释放 tsfn —— 不注销也不会漏内存(tsfn 的 finalize 会兜底),但会多留一份订阅。 */
int bsh_ui_unsubscribe(int sid);

/* 推一个 JSON 事件给 ArkTS(单向),**广播给所有已订阅的窗口**。
 * 刻意的选择:keys/win-scale/right-click 是全局设置,应该对所有窗口一起生效 ——
 * 只发给"最后一个订阅的"会让先开的窗口与新开的窗口表现不一致。
 * 一个订阅者都没有时返回 -1。 */
int bsh_ui_notify(const char* json);

/* 发一个**要回结果**的请求:事件里会自动补 "req":<id> 字段,然后阻塞等待
 * ArkTS 调 bsh_ui_resolve(id, …) 回填。out 收到 ArkTS 给的文本(通常是给用户
 * 看的一句话)。返回 0 成功 / -1 = 该会话没订阅、投递失败或超时。
 *
 * ⚠ sid 是**精确匹配**、不做兜底:请求类动作(picker / newtab)必须在"发起命令的那个
 * 窗口"里发生 —— 弹在别的窗口上会让人莫名其妙。sid 由 bshutil 客户端从自己的
 * BSH_SESSION 环境变量读出来、随请求带给服务端(见 bsh_util_proto.h)。 */
int bsh_ui_request(int sid, const char* json, char* out, size_t cap, int timeout_ms);

/* ArkTS 侧回填某个请求的结果(bshUiResolve 的 native 侧)。 */
int bsh_ui_resolve(int req_id, const char* result);

#ifdef __cplusplus
}
#endif
