// bshutil/bsh_util_proto.h — bshutil 服务端(主进程线程)与客户端(命令 so)共用的协议
//
// 为什么要有这个头:帧格式是**两侧必须一致**的约定,而两侧是分开编译的
// (服务端在 libentry.so 里,客户端在 libbshutil.so 里),各写一份字面量迟早会漂。
#pragma once

/* 一帧 = 4 字节大端长度 + payload(文本,多行)。上限只用来挡住坏数据。 */
#define BSHUTIL_MAX_FRAME (256 * 1024)

/* 应答的收尾:输出字节之后跟 4 字节大端退出码,然后服务端 shutdown(SHUT_WR)。
 * 客户端据此把"最后 4 字节"当退出码,前面的字节全部当输出(所以输出是流式的,
 * 服务端不需要攒齐再发)。 */
#define BSHUTIL_CODE_LEN 4
