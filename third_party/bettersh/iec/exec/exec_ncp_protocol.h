// exec/exec_ncp_protocol.h — what the server and the loaded library agree on.
//
// The platform passes one string to the entry it calls in the new process, so the
// request is packed into it: two characters that cannot appear in a path, a symbol
// name or an argument, and the same reader on both sides.
#pragma once

// The library the platform loads into the child and the entry it calls in it.
// Spelled with a colon between them because that is the form
// OH_Ability_StartNativeChildProcess() takes.
#define IEC_NCP_LIBRARY "libncploader.so"
#define IEC_NCP_ENTRY "IecNcpMain"
#define IEC_NCP_ENTRY_FULL IEC_NCP_LIBRARY ":" IEC_NCP_ENTRY

// Fields within a section, sections within the payload.
constexpr char kIecNcpField = '\x1f';
constexpr char kIecNcpSection = '\x1e';

// Where the loaded library leaves the program's exit code. The platform's exit
// callback reports a signal and nothing else, so the code has to come back another
// way; a small file under the fake root's log directory is enough, and the callback
// removes it once read. The pid is appended to this prefix.
#define IEC_NCP_EXIT_PREFIX "/logs/iec-exit."
