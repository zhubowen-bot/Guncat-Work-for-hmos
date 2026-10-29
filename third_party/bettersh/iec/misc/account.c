// misc/account.c — synthetic passwd entries for the sandbox.
//
// The sandbox's /etc/passwd contains system accounts only, so
// getpwuid(getuid()) returns NULL. dropbear's fill_passwd() then has no
// pw_name, checkusername() rejects every login, and the client warns that it
// cannot identify the current user.
//
// The entries are deliberately conservative:
//   - getpwuid(uid) answers only for this process's own uid;
//   - getpwnam(name) answers only for IEC_SSH_USER (default "user").
// dropbear's rule that a non-root server may authenticate only its own uid
// therefore still holds: asking for root still gets no entry.
//
// seteuid/setegid: the sandbox does not allow changing identity and kills the
// process instead of returning an error. The synthetic entry names the current
// uid/gid, so the calls dropbear makes around authorized_keys are no-ops;
// short-circuit them. Any other target fails, because there is no privilege to
// gain here.
//
// pw_shell is the bare name "sh", not "/bin/sh":
//   - dropbear's run_shell_command() execs this string, and a bare name goes
//     through the exec shim to the IEC exec service, which finds the launcher
//     in the fake root (the sandbox's /bin is EACCES);
//   - dropbear's checkusername() validates it against getusershell(), which
//     falls back to COMPAT_USER_SHELLS when /etc/shells is missing; the build
//     sets that constant to the same name.
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "constant.h"

#define IEC_SSH_DEFAULT_USER "user"
#define IEC_SSH_SHELL "sh"

static const char* IecUserName(void) {
    const char* u = getenv("IEC_SSH_USER");
    return (u && *u) ? u : IEC_SSH_DEFAULT_USER;
}

static const char* IecHomeDir(void) {
    const char* h = getenv("HOME");
    return (h && *h) ? h : IEC_DEFAULT_HOME;
}

static struct passwd* IecFillPasswd(struct passwd* pw) {
    pw->pw_name   = (char*)IecUserName();
    pw->pw_passwd = (char*)"x";
    pw->pw_uid    = getuid();
    pw->pw_gid    = getgid();
    pw->pw_gecos  = (char*)"";
    pw->pw_dir    = (char*)IecHomeDir();
    pw->pw_shell  = (char*)IEC_SSH_SHELL;
    return pw;
}

struct passwd* getpwuid(uid_t uid) {
    static struct passwd pw;
    if (uid != getuid()) return NULL;
    return IecFillPasswd(&pw);
}

struct passwd* getpwnam(const char* name) {
    static struct passwd pw;
    if (strcmp(name, IecUserName()) != 0) return NULL;
    return IecFillPasswd(&pw);
}

int seteuid(uid_t uid) { return (uid == geteuid()) ? 0 : -1; }
int setegid(gid_t gid) { return (gid == getegid()) ? 0 : -1; }
