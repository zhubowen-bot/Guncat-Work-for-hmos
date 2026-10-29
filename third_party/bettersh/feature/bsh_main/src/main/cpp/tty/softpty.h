// tty/softpty.h — BetterSH 软伪终端
// 沙箱无真 pty / fork-pty:用 socketpair 模拟 master/slave 两端的字节通道,
// 并维护一份"终端状态"(默认 termios、winsize),供上层 shell/guest shim 查询。
#pragma once

#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <termios.h>

namespace bsh {

struct PseudoTty {
    int master = -1;   // 应用/前端侧:写输入、读输出
    int slave  = -1;   // 会话(shell/guest)侧:读输入、写输出
    struct winsize ws { .ws_row = 24, .ws_col = 80 };
    struct termios tio;   // 模拟的默认终端属性(ICANON|ECHO|OPOST|ONLCR|ISIG)
};

// 创建一对 socketpair 作为 pty;失败返回 false。tio 置默认。
bool PseudoTtyCreate(PseudoTty* p);

// 关闭两端。
void PseudoTtyClose(PseudoTty* p);

// 更新/读取终端尺寸( guest 的 TIOCSWINSZ/TIOCGWINSZ 落到这)。
void PseudoTtySetSize(PseudoTty* p, uint16_t rows, uint16_t cols);
void PseudoTtyGetSize(const PseudoTty* p, uint16_t* rows, uint16_t* cols);

}  // namespace bsh
