//
#pragma once

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct terminal_session terminal_session_t;

typedef void (*terminal_output_cb)(
    terminal_session_t* session,
    const char* data,
    size_t size,
    void* user_data
);

typedef void (*terminal_exit_cb)(
    terminal_session_t* session,
    int exit_code,
    void* user_data
);

terminal_session_t* terminal_start(
    int cols,
    int rows,
    terminal_output_cb output_cb,
    terminal_exit_cb exit_cb,
    void* user_data
);

ssize_t terminal_input(
    terminal_session_t* session,
    const char* data,
    size_t size
);

int terminal_resize(
    terminal_session_t* session,
    int cols,
    int rows
);

int terminal_pid(terminal_session_t* session);

void terminal_stop(terminal_session_t* session);

#ifdef __cplusplus
}
#endif
